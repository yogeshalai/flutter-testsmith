# E-02 — Real Figma integration

Consuming an actual Figma file over the actual Figma API, and comparing
it deterministically against the Flutter UI of an application outside
this repository.

Read this if you are about to point the platform at a design, or if you
want to know what the comparison can and cannot yet say.

---

## 1. The real Figma file

Nothing in this milestone is synthetic. No design JSON was hand-authored,
no Flutter dimension was copied into a spec, and no model was asked what
a screen should look like.

| | |
|---|---|
| File key | `<redacted>` |
| File name | *(redacted)* |
| Last modified | `2026-09-08T12:42:18Z` |
| Version | *(redacted)* |
| Canvases | `Shopping App`, `Dev Space`, `D2C` — 484 top-level nodes between them |

### Nodes used

| Node | Name | Size | Nodes in frame | Used for |
|---|---|---|---|---|
| `909:1` | Login | 402×874 | 181 | The screen under test, on a real device |
| `912:2` | DashBoard | 402×2597 | 274 | Second real node: fetch, normalise, coverage |
| `913:1` | Product Details | 402×1198 | — | Pre-existing real capture, still exercised |
| `<redacted>` | Login (Dev Space) | 402×874 | — | Read once, to confirm `909:1` is the right frame |

`909:1` was confirmed as the correct frame rather than assumed. The
file holds a second `Login` in the `Dev Space` canvas; it is the same
layout translated 30px up (every horizontal coordinate identical, every
vertical one exactly 30 less), and the running application sits closer to
`909:1`.

### Credentials

`FIGMA_TOKEN` is resolved the way every other credential in this platform
is: the process environment first, then the first `.env` found beside the
application and then beside the caller. That is `DotEnv` and
`EnvSecretResolver`, the same pair `testsmith run`, `suite run`, `auth
setup` and `generate` use, so CI — which sets variables properly — is
never overridden by a local file, and `.env` is gitignored.

It is **never** accepted as a command-line flag: a flag lands in shell
history and in the process list. `testsmith figma pull` read the
environment directly until the credential path was unified, which meant a
token living only in `<app>/.env` resolved for a run and not for the pull
that produced the spec that run reads.

Where the token *goes* is unchanged and is what section 10 is evidence
for: one HTTP header, and nowhere else.

---

## 2. The API surface actually used

The smallest subset that supports the comparison, not a client for Figma.

| Endpoint | Used for | Where |
|---|---|---|
| `GET /v1/files/{key}/nodes?ids={id}` | Every frame the platform compares against | [figma_client.dart:143](../integrations/flutter_testsmith_figma/lib/src/figma_client.dart#L143) |
| `GET /v1/files/{key}?depth=N` | Finding frames by name when writing a mapping. Never used by a run | manual |

Both are `GET`, both authenticate with the `X-Figma-Token` header. Nothing
writes to Figma.

Responses are cached on disk per file+node. This is not an optimisation:
Figma rate-limits, a design does not change between two steps of one run,
and re-fetching a 140KB frame for every validation would make runs slow
and fragile. The cache stores the response only — the token is not part
of it — and `--refresh` bypasses it.

Fields read from a node: `id`, `name`, `type`, `children`,
`absoluteBoundingBox`, `visible`, `opacity`, `fills[]`
(`type`/`visible`/`opacity`/`color`), `cornerRadius`, `style`
(`fontFamily`/`fontSize`/`fontWeight`/`lineHeightPx`/`letterSpacing`/`textAlignHorizontal`),
`characters`, `layoutMode`, `itemSpacing`, `paddingLeft/Top/Right/Bottom`.
Everything else in the response is ignored.

---

## 3. The normalised model

Raw Figma JSON never reaches the validator. The engine consumes
`FigmaScreenSpec`, which is written to disk as `figma/<screen>.json` and
committed, so a design change arrives as a reviewable diff.

```
FigmaScreenSpec
  screen                which application screen this describes
  nodeId, figmaName     provenance, preserved verbatim
  width, height         the frame's own size
  elements[]            flat list; hierarchy is an adjacency list (§3.1)
  totalNodesWalked      every node inside the frame
  unmatchedMappings[]   mapped node ids not present in the frame
  coverage              derived counts (§7)

FigmaElement
  nodeId                Figma's id. Survives a layer rename
  figmaName             the layer name, as a hint only — never an identifier
  parentNodeId          nearest *kept* ancestor, or null for a frame child
  semanticId            assigned by the mapping file, never inferred
  type                  TEXT / IMAGE / SHAPE / CONTAINER / INSTANCE / VECTOR
  rect                  frame-relative, in the design's logical pixels
  visible, opacity      Figma's own; opacity defaults to 1
  fill                  `#rrggbbaa`, first visible solid fill
  cornerRadius          uniform only
  typography            family, size, weight, line height, letter spacing, align
  layout                auto-layout only: direction, itemSpacing, padding
  horizontal, vertical  the declared anchor and sizing per axis (§3.2)
  unclippedRect         the box before a clipping ancestor cut it, if any
```

Three things the real API forces, none of them obvious from the
documentation, all found by reading real responses:

1. `absoluteBoundingBox` is in **canvas** coordinates. The Login frame
   sits at x = −126544, so every element is re-expressed relative to the
   frame's own origin.
2. Colours arrive as 0..1 floats, and a fill's own `opacity` is separate
   from its colour's alpha. Both are folded into one `#rrggbbaa`. A
   node's `opacity` is deliberately **not** folded in — Figma treats them
   as different things and so does Flutter, where `Opacity` is a
   different render object from a decoration colour.
3. Most nodes are vector paths inside icon groups. They are dropped, or a
   frame of a dozen visible things reports two hundred elements. The walk
   still descends through them, because a group holding a vector may also
   hold a label.

### 3.1 Hierarchy as an adjacency list

`children` is reconstructed, not stored. `FigmaElement.parentNodeId`
points at the nearest **kept** ancestor, and `FigmaScreenSpec` exposes
`childrenOf`, `ancestryOf` and `isAncestor`.

Storing a nested tree would have duplicated it on disk and churned the
spec format, the CLI, the project indexer and every existing comparison
for no gain. Pointing at the nearest *kept* ancestor matters: a node
whose parent was pruned as a vector would otherwise reference a node the
spec does not contain, and every hierarchy question about it would answer
"no ancestor" instead of the truth.

### 3.2 Declared layout semantics

Each element also carries, per axis, the **anchor** it is positioned from
and what determines its **length** — read from the parent's auto-layout
alignment for an auto-layout child, and from its own `constraints` for an
absolutely positioned one.

This is what makes a design coordinate comparable on a device of a
different size, and it replaced a width-scaling model that manufactured
error proportional to distance from the origin. It has its own document:
[E-02_PROJECTION_MODEL.md](E-02_PROJECTION_MODEL.md).

---

## 4. Matching Figma nodes to Flutter elements

Three stages, in order, with no fallback at any of them.

```
Figma node id ──(mapping YAML, hand-written)──▶ semantic id ──(exact ==)──▶ UiNode.testId
```

| Condition | Verdict | Validator |
|---|---|---|
| exactly one `UiNode` carries that testId | compared | — |
| none | **FAIL** — an application defect | `figma-structure` |
| more than one | **ERROR** — identity cannot be established | `figma-identity` |
| mapping names a node not in the frame | **ERROR** — stale mapping | `figma-mapping` |
| two Figma nodes mapped to one semantic id | rejected when the mapping is parsed | — |
| a comparable node no mapping names | not compared; counted in coverage | `figma-coverage` |

**There is no name-based, text-based or geometric fallback, and there
will not be one.** The reason is visible in the file this was built
against: the Dashboard frame contains fifty-three separate TEXT layers
all named `label-text`, and the Login frame's card is called
`Frame 43319`. A layer name is not an identifier. Matching on one would
not fail honestly — it would look like it worked.

Ambiguity produces an `error`, not a `fail`, and stops the comparison for
that element. Both block the run, but only one of them accuses the
application; a duplicated test id is a tooling problem, and resolving it
by picking the first match would produce a confident verdict about an
element nobody chose.

### The mapping file

`external_app/figma/login.mapping.yaml`, bound by node id so a rename in
Figma cannot silently break it:

| Figma node | Semantic id | What it is |
|---|---|---|
| `909:2` | `login.background` | background artwork, 20% opacity |
| `909:16` | `login.card` | the card. Auto-layout, 20/24/20/24, gap 20, radius 16 |
| `909:18` | `login.welcome_title` | "Welcome!" |
| `909:19` | `login.welcome_subtitle` | "Use your mobile number or Google to continue" |
| `909:23` | `login.mobile_field` | the number field, 322×50, radius 10 |
| `909:125` | `login.country_code` | "+91" |
| `909:127` | `login.continue_button` | Add Button, 322×48, radius 8 |
| `909:129` | `login.divider_label` | the "Or" rule |
| `909:133` | `login.google_button` | Add Button, 322×48, radius 8 |
| `909:141` | `login.policy_text` | the terms sentence |
| `909:145` | `login.skip_button` | the Skip pill, 53×26, radius 18 |

Each entry names the node whose **box** corresponds to the widget, which
is not always the node whose text you recognise. Continue is `909:127`
— the 322×48 frame — not `909:128`, the 66×18 label inside it. Mapping
the label would compare a button's bounds against a word.

---

## 5. Deterministic comparison rules

Every comparison produces exactly one of `pass`, `fail`, `skip` or
`error`. `skip` and `error` are not `fail`: conflating "not configured"
with "the price is wrong" teaches people to ignore failures. `error`
still blocks the run — a check that could not run has not shown the
screen to be correct.

| Validator | Compares | Skips when |
|---|---|---|
| `figma-structure` | the mapped element is present and visible | — |
| `figma-identity` | the test id resolves to one element | — |
| `figma-type` | TEXT renders text; IMAGE is an image | the design says IMAGE and the widget might paint one |
| `figma-geometry` | x (or the anchored edge), y, width, height | no viewport; vertical when the aspects differ too much |
| `figma-hierarchy` | ancestry the design declares holds on screen | fewer than two matched elements |
| `figma-spacing` | the gap between adjacent mapped siblings | a vertical gap on an aspect-incomparable frame |
| `figma-padding` | declared padding vs measured content inset | a side where the design does not hug its own content |
| `figma-typography` | font size, weight, family (off by default) | the app reported no text style |
| `figma-colour` | text colour, or a container's fill | the app reported neither |
| `figma-opacity` | node opacity | the design is fully opaque; the app reported none |
| `figma-radius` | uniform corner radius | the design declares none; the app reported none |
| `figma-text` | rendered copy against design copy | `text: ignore`, which is the default |
| `figma-order` | top-to-bottom order of matched elements | fewer than two matched |
| `figma-unexpected` | ids on screen the design does not contain | off by default |
| `figma-coverage` | nothing — it reports denominators (§7) | — |

### Geometry is compared in projected space

A design is authored at one width — 402pt here — and the app runs at
whatever the device reports (384 logical pixels on the test device).
Comparing raw coordinates would report every element as misplaced.
`DesignProjection.fitWidth` scales by **width**, because that is how
designs are authored: a layout is drawn to a canvas width and expected to
stretch vertically.

When the design frame and the viewport differ in aspect by more than
`aspectDelta`, vertical positions are **skipped**, with the numbers in
the message. The Dashboard frame is 402×2597 against an 853-tall
viewport; comparing its vertical positions would be arithmetic, not
information.

### Hierarchy is asymmetric, deliberately

If the design puts A inside B, B's element must contain A's element. If
the design makes them siblings, **nothing is asserted**. Flutter trees
are far deeper than design trees, and a legitimate `Padding`, `Center` or
`Semantics` wrapper would otherwise read as a defect. What survives is
the check that catches a real inversion — an element re-parented out of
the container the design put it in, which no amount of correct geometry
can excuse.

### Spacing is measured on both sides

Figma states spacing on an auto-layout frame. Flutter states it nowhere a
test id can reach: `Padding` is a separate widget, and the retention
policy drops it. So both sides are *measured* from geometry:

- a **gap** is the distance between two adjacent mapped siblings,
- **padding** is the inset from a container to its content.

Measuring both sides the same way is what makes the comparison mean
anything. Two guards keep it honest:

- A gap is only compared when nothing **unmapped** sits between the two
  children in the design — an unmapped sibling contributes its own size
  and two gaps, none of which is visible from here.
- A padded side is only compared when the design's *declared* padding
  agrees with the design's *own* measured inset. A fixed-size frame with
  space-between alignment declares padding it does not hug, and comparing
  that against a measurement would fail an application that is correct.
  The skip says which sides and why.

Both insets are measured from the **same** children — the mapped ones on
each side. Measuring Flutter from every retained child instead compares
two different content boxes: partial mapping is the normal case, and an
unmapped full-bleed divider inside a card puts Flutter's inset at 0
against the design's 20. That was a real defect in this milestone, caught
by a test written from the real mapping before the device run (§8).

### Which colour is read is decided by the design

A TEXT node's fill is the colour of its glyphs, so the text is read —
including from a descendant, because the id belongs on the button while
the design's TEXT node describes the label inside it. Any other node's
fill is the colour *behind* its content, so the element's own paint is
read and nothing below it is consulted.

This rule was arrived at from the real run, not from first principles:
reading text first reported the Continue button as `#1a1a1ae6` against a
design of `#fffaf5ff`, a 229-channel difference the comparison had
invented out of the button's own label.

### AI is not in the verdict

No validator consults a model. `ValidationResult` has no confidence
field, and two tests assert that it never gains one — including now at
any nesting depth inside `facts`, the map E-02 added for coverage.
`testsmith run --ai` may ask a model to *explain* a failure after the fact;
it cannot create, change or clear one.

---

## 6. Tolerances

Every threshold is in one object, `FigmaTolerances`, and every one is
configurable per screen under `figma:` in that screen's mappings file. A
number buried at a call site is a number nobody revisits.

| Setting | Default | Meaning |
|---|---|---|
| `positionPx` | 4 | projected position drift, device logical px |
| `sizePx` | 3 | width/height difference |
| `spacingPx` | 4 | gap or padding difference |
| `fontSizePx` | 1 | font size difference |
| `fontWeightSteps` | 0 | weight difference, in 100-unit steps |
| `colourChannelDelta` | 8 | per-channel 8-bit difference |
| `opacityDelta` | 0.02 | opacity difference, 0..1 |
| `cornerRadiusPx` | 2 | corner radius difference |
| `aspectDelta` | 0.05 | how differently shaped before vertical is skipped |
| `text` | `ignore` | design copy is placeholder unless a screen opts in |
| `textAnchor` | `left` | which horizontal edge a text element's layout fixes |
| `checkGeometry/Ordering/Typography/Colour` | on | |
| `checkHierarchy/Spacing/Opacity/CornerRadius` | on | added by E-02 |
| `checkFontFamily` | off | Flutter reports `packages/x/Inter`; themes substitute |
| `checkTextSize` | off | a text node's box is typeset, not laid out |
| `reportUnexpected` | off | screens legitimately carry undesigned elements |

`spacingPx` is its own setting rather than a reuse of `positionPx`: a gap
is the difference of two positions and carries both their errors, so
tying them together would mean loosening position tolerance to quiet a
spacing report.

`opacityDelta` is not zero because Figma stores 0.2 as
`0.20000000298023224`.

`external_app/mappings/login.yaml` restates every default explicitly. A
tolerance that is invisible is a tolerance nobody reviews. **Nothing on
this screen has been loosened**, and the run in §9 fails with the
platform defaults exactly as shipped.

---

## 7. Comparison coverage

"8 checks passed" is a true sentence that invites a false conclusion. A
frame holds hundreds of nodes; a mapping binds a handful; the verdict
covers the handful. Every Figma validation therefore emits a
`figma-coverage` result carrying the denominators, in prose and in
machine-readable `facts`:

```
Figma nodes: 181 in the "Login" frame (90 comparable, 91 decorative).
Mapped: 11.  Compared: 11.  Unmapped: 79.
Coverage: 12.2% of comparable nodes.
Checks: 39 passed, 11 failed, 0 errored, 10 skipped.
Verdict scope: mapped elements only.
```

Three populations, not two, so the percentage means something:

- **decorative** (91) — vector paths inside icon groups, and nodes laid
  out to nothing. Never comparable, by construction.
- **unmapped** (79) — comparable, but no mapping names them. Not a
  defect, and not covered either.
- **mapped** (11) — the only elements any verdict speaks about.

`verdictScope` is stated on every run, and it is always
`mapped elements only`. A `PASS` from this platform means *the mapped
elements agreed*; it has never meant *the screen matches the design*, and
now it cannot be read that way by accident.

---

## 8. Negative-test evidence

Thirteen seeded Flutter-side defects, each changing exactly one property
of one widget. Every side is real: the design is the real `909:1`
capture, the UI is real Flutter widgets captured by the real
`UiTreeInspector` including its retention policy, and the verdict is the
real `FigmaStructureValidator`. Nothing between them is stubbed.

The full table is generated by the run that proves it:
[docs/evidence/figma_flutter_defect_matrix.md](evidence/figma_flutter_defect_matrix.md).
Summarised:

| # | Seeded defect | Result |
|---|---|---|
| 1 | wrong width | FAIL `figma-geometry` |
| 2 | wrong height | FAIL `figma-geometry` |
| 3 | wrong position | FAIL `figma-geometry` |
| 4 | wrong colour | FAIL `figma-colour` |
| 5 | wrong font size | FAIL `figma-typography` |
| 6 | wrong font weight | FAIL `figma-typography` |
| 7 | missing node | FAIL `figma-structure` |
| 8 | unexpected node | FAIL `figma-unexpected` |
| 9 | hierarchy mismatch | FAIL `figma-hierarchy` |
| 10 | ambiguous identity | **ERROR** `figma-identity` |
| 11 | wrong corner radius | FAIL `figma-radius` |
| 12 | wrong opacity where the design declares none | nothing compared, and said so |
| 13 | wrong gap | FAIL `figma-spacing` |

Two rows carry more than their number suggests:

- **Case 9** changes *only* the nesting. Geometry, style and id are
  untouched, and the test asserts that geometry stays clean — so the row
  proves the hierarchy check is doing the work rather than riding along
  with a position change.
- **Case 12** is the only row where nothing fails. The design declares no
  opacity for that node, so the platform compares nothing rather than
  inventing a default of 1 to compare against. Asserting the *absence* of
  a comparison is how a check that silently stopped running gets caught.

The matrix opens with a **control**: an implementation built to the
design passes with zero blocking results. Without it the other thirteen
rows would be satisfied by a comparison that fails everything.

Two further rows prove tolerance is real and configurable: a 3px drift
passes at the default `positionPx: 4`, and the same drift fails at
`positionPx: 1`.

---

## 9. The real `external_app` run

### What was instrumented, and what was not

The Login screen carried **zero** test ids. Eleven were added, plus two on
the onboarding screen the flow passes through. **Instrumentation only** —
no layout, geometry, padding, styling, typography or behaviour was
changed, and nothing was tuned to make a comparison pass.

That is asserted mechanically rather than promised. With every `TestId`
wrapper and the one added import removed, the instrumented
`login_screen.dart` is **character-for-character identical** to the
original:

```
original      : 13620 chars (whitespace-stripped)
instrumented  : 13620 chars, after removing every TestId wrapper and the import
IDENTICAL     : True
```

The two onboarding ids exist to *reach* the screen under test, not to
compare it: `onboarding.get_started` is the only way past the Get Started
screen on a device with cleared data, and `onboarding.illustration` names
a Lottie so it can be **declared** in a quiescence exception — an
animation with no semantic id cannot be named, only ignored wholesale.

### Running it

```bash
adb shell pm clear com.example.testapp.alpha     # sign out; see below
adb shell pm grant com.example.testapp.alpha   android.permission.POST_NOTIFICATIONS                 # see login.yaml
export FIGMA_TOKEN=...
dart run packages/flutter_testsmith_cli/bin/testsmith.dart figma pull \
  --file-key <redacted> --node-id 909:1 --screen /login \
  --out ../external_app/figma --mapping ../external_app/figma/login.mapping.yaml
dart run packages/flutter_testsmith_cli/bin/testsmith.dart run ../external_app/mytest/tests/login.yaml \
  --app ../external_app -d <serial> --mock-api 8080 \
  -t lib/main_mytest.dart --flavor example --out out/e02-login
```

Device: Samsung SM M127G, Android 13, 720×1600 physical, 384×853.3
logical at dpr 1.875.

### Result: FAIL — 43 checks passed, 8 failed, 0 errored, 10 skipped

> These are the numbers **after** the projection model of
> [E-02_PROJECTION_MODEL.md](E-02_PROJECTION_MODEL.md). The first run of
> this screen reported 39 / 11 / 10, and three of those eleven failures
> were the projection's own arithmetic rather than anything about the
> application. See that document for the before-and-after.

Every mapped element was found and matched (11/11 `figma-structure`
passes). All eight hierarchy assertions passed. Spacing, padding, order
and opacity passed. **The eleven failures are real differences between
the application and the design**, and per the milestone's own
instruction they are reported rather than tuned away.

| Element | What differs |
|---|---|
| `login.policy_text` | reads "…Privacy Policy"; the design says "…Privacy Policy **and Content Policy**" |
| `login.policy_text` | font weight 400, the design says 500 |
| `login.policy_text` | vertical inset 708.3 vs 675 — the app pins it to the bottom, the design flows it |
| `login.card` | vertical inset 302 vs 322 — the content above it differs in height |
| `login.divider_label` | vertical 241 vs 230; width 302 vs a fixed 314 |
| `login.google_button` | vertical 280 vs 269 — the same accumulated 11px |
| `login.skip_button` | vertical centre offset 12.8 out — the design assumes a taller status area than this device has |
| `login.background` | inset 24 vs 60, and 384×781 vs a fixed 402×814 |

Three causes, and they are worth separating because only one is a defect
in the ordinary sense:

1. **A copy discrepancy.** The application's terms sentence omits "and
   Content Policy". A genuine finding of exactly the kind this milestone
   exists to surface, found by comparing strings — not by a model's
   opinion.
2. **Content-flow differences.** The card sits 20px higher than the
   design puts it because what is above it renders at a different
   height, and that difference accumulates down the screen. Real, and
   visible as an 8px spacing difference above the divider.
3. **A status-bar assumption.** The design places its background at y=60
   and its Skip pill accordingly; this device's inset is 24. The design
   declares no safe area, so the platform reports the difference rather
   than assuming one. See the projection document, §7.

### The ten skips are informative, not noise

Five `figma-radius` and three `figma-colour` skips all have one cause,
and the message names it: the test id sits on a widget whose render
object is not a decorated one. `TestId(child: Container(width:, padding:,
decoration:))` resolves to a `RenderConstrainedBox`, with the decoration
one level below. The inspector does not look below (§11), so it reports
nothing and the comparison says so. The fix is in the application — move
the id onto the `DecoratedBox` — and was deliberately **not** made, since
it would be changing the app to improve a result.

### The Dashboard

`912:2` is fetched, normalised and committed as
`external_app/figma/home.json`: 274 nodes, 213 comparable. It carries no
mapping yet, so its comparison reports a `skip` saying exactly that
rather than a hollow pass. It is the second real node ID, and it is what
demonstrates the aspect guard: 402×2597 against an 853-tall viewport
would make every vertical comparison arithmetic rather than information.

### Two platform defects the real run found

Both were fixed with a failing test first, and both would have produced
wrong answers on any application:

1. **`currentScreenId` believed the removal of a background route.**
   `context.go` from a splash pushes the destination and *then* removes
   the splash; a removed route has nothing beneath it, so the exit
   carries no next screen. Read literally that says "the app is on no
   screen", and `expectScreen` waited out its whole timeout while sitting
   on exactly the screen it asked for. Intermittently — it depended on
   whether a poll landed before the removal did. An exit now only moves
   the current screen when it is the current screen leaving.
2. **The colour comparison descended into text for non-text nodes**, as
   described in §5.

One non-defect worth recording: a tap dispatched at coordinates read
*mid-route-transition* lands where the button is going to be rather than
where it is, and the flow then reports a tap that happened and a
navigation that did not. Settling before the tap removes the race, which
is why `mappings/onboarding.yaml` declares the looping illustration —
without the declaration there is nothing to settle on.

---

## 10. Security evidence

The token is supplied through the environment, put into one HTTP header,
and goes nowhere else.

`integrations/flutter_testsmith_figma/test/token_redaction_test.dart` uses a
sentinel shaped like a real Figma personal access token and asserts it
appears in none of:

- the message of a `FigmaException` from a 403, a 404, or a non-JSON
  response,
- any file the on-disk cache writes, or any cache file's **name**,
- the normalised spec, serialised whole,
- a `FigmaTarget` rendered for a log line.

The first test in that file asserts the token *is* sent, so the rest is
known to be testing something.

**The test was proved able to fail.** Injecting the classic leak — an
error message that quotes the request it made — turns two of its cases
red; reverting turns them green:

```
--- with the token quoted into an error message: ---
Failing tests:
  the token is not in the message when Figma rejects it
  the token is not in the message when the file is missing
--- restored ---
All tests passed!
```

And against the artefacts of the real run, scanned for the real token:

```
no occurrence of the token in any of:
  out/e02-login/report.html
  out/e02-login/result.json
  external_app/figma/.cache/<redacted>.909-1.json
  external_app/figma/.cache/<redacted>.912-2.json
  external_app/figma/home.json
  external_app/figma/login.json
  external_app/figma/login.mapping.yaml
```

Two further precautions:

- `figma/.cache/` is gitignored in `external_app`. The *normalised* specs
  beside it are committed on purpose: they are what a comparison reads,
  and a design changing should show up as a reviewable diff.
- The committed fixtures have `thumbnailUrl` stripped. It is a presigned
  S3 link carrying AWS credential material in its query string, it
  expires, and it is not part of the design.

---

## 11. Known Figma limitations

Recorded because each one is a place the platform will say less than you
might assume.

| Limitation | Consequence |
|---|---|
| **Only the first visible solid fill is read.** Figma's `fills` is a stack; gradients and image fills are not colours. | A gradient-filled node reports no colour and its comparison skips. |
| **Corner radius must be uniform.** Figma reports one `cornerRadius` only for uniform rounding; a sheet rounded at the top has four values. | A non-uniform radius is not compared, on either side. |
| **The normaliser does not clip an element to its frame.** `absoluteBoundingBox` is the unclipped box. | `login.background` is 542.7px wide inside a 402px frame, and its geometry comparison is meaningless. Visible in §9. |
| **`ColoredBox` reports no fill.** Its render object is private and publishes no colour, through diagnostics or otherwise. `Container(color:)` builds one too. | The comparison reports that it could not read a fill. Reading it would require special-casing a widget type, which §11's rule forbids. |
| **A sized `Container` hides its own decoration.** `Container(width:, height:, decoration:)` builds a `ConstrainedBox` around a `DecoratedBox`, so the id resolves to the constraint box. | Five radius skips and three colour skips in the real run. |
| **Text boxes are typeset, not laid out.** A TEXT node's width comes from the font; the font is compared absolutely while geometry is compared in projected space. | `checkTextSize` is off by default. The font itself is still compared exactly. |
| **Component instances are not resolved.** An `INSTANCE` is read as laid out, not traced to its main component. | An override that differs from the component is invisible. |
| **Auto-layout only for spacing.** A frame positioned absolutely declares no spacing. | Spacing comparison is silent there, rather than inventing zero. |
| **Effects, strokes, blend modes and rotation are not read at all.** | Shadows and borders are never compared. |

### The SDK rule this rests on

> **A test id identifies one render object. That render object is
> inspected directly. No descendant search, no widget-type special case,
> no inference.**

Opacity, fill and corner radius are read from `element.renderObject` —
the same render object the bounds come from — and from nowhere else.
Where it does not carry the property, none is reported and the
comparison says it could not read one, naming the fix.

The alternative, "find the nearest `Container` and read its decoration",
puts a value in the report that belongs to a widget nobody named, with
nothing in the report to say it happened. Several tests assert the
absence of that behaviour, including one that a `Card` gets no special
treatment.

---

## 12. Remaining work before public Figma integration

1. **A projection model that matches how applications actually scale.**
   `fitWidth` assumes everything scales by width. `external_app` scales
   horizontal padding as fixed logical pixels and vertical rhythm by
   height. Most of §9's geometry failures are this disagreement rather
   than a design defect, and no tolerance setting is the right answer —
   a tolerance wide enough to absorb 63.6px would absorb real defects
   too. This is the single biggest blocker to a Figma comparison that
   means what people expect on a device unlike the design canvas.
2. **Clip elements to their frame** when the frame clips content, so an
   overflowing artwork is comparable.
3. **Safe-area awareness.** The design frame includes a status bar of an
   assumed height; the device reports its own. Until the projection knows
   about insets, every top-anchored element on a device with a different
   inset is out by the difference.
4. **A `clearAppState` step.** Reaching a signed-out screen currently
   needs `adb shell pm clear` outside the flow, which makes the flow not
   self-contained. It is documented as a precondition in `login.yaml`;
   it should be expressible.
5. **Non-uniform corner radii, gradients and strokes**, each of which
   needs a comparable representation on both sides before it can be
   compared at all.
6. **Component instance resolution**, so an instance can be compared
   against its main component's intent.
7. **Mapping ergonomics.** `--write-mapping-template` lists every
   candidate; on the Dashboard that is 213 rows. Binding eleven nodes by
   hand was manageable; binding a whole application will not be.
8. **A second real application.** Everything here is calibrated against
   one design file and one app. The projection question in (1) is
   exactly the kind of thing that looks like a bug in one app and a rule
   in two.

---

## 13. Acceptance

| # | Criterion | Status |
|---|---|---|
| 1 | A real Figma file is consumed | **met** — `<redacted>`, live API, HTTP 200 |
| 2 | Real API data becomes the normalised model | **met** — §3; three real nodes normalised |
| 3 | Real `external_app` Flutter UI is inspected | **met** — on a Samsung SM M127G, 11 ids resolved |
| 4 | Figma → Flutter comparison is deterministic | **met** — §5; no model in any verdict |
| 5 | At least one real screen passes | **NOT met** — see below |
| 6 | At least five intentional mismatches fail correctly | **met** — thirteen, §8 |
| 7 | Ambiguity produces ERROR rather than guessing | **met** — §4, matrix row 10 |
| 8 | AI is not responsible for PASS/FAIL | **met** — asserted, including inside `facts` |
| 9 | No credentials leak | **met** — §10, with the test proved able to fail |
| 10 | Analyzer / tests / dependency rules clean | **met** — see below |

### On criterion 5

The Login screen does **not** pass. 43 of its 51 non-skipped checks pass,
and the 8 failures are genuine differences between this application and
this design (§9) — one a real copy defect, the rest content-flow and
status-bar differences.

This was investigated before being accepted. The first run reported 11
failures, and **three of those were the platform's own arithmetic**: a
width-scaling projection that treated design coordinates as scalable
quantities. Replacing it with a model built from the anchors Figma
actually declares removed those three and left the rest unchanged, with
no tolerance loosened and no mapping dropped. That work has its own
document: [E-02_PROJECTION_MODEL.md](E-02_PROJECTION_MODEL.md).

What remains is the honest answer to the question the milestone asked.
The design and the application genuinely disagree, so the acceptance
interpretation is this:

> Criterion 5 is met in substance — the comparison is correct, and its
> verdict is trustworthy — and not in letter, because the application
> does not match the design. A green result was reachable by setting
> `positionPx` to 64 or by dropping the six worst elements from the
> mapping. Both would have been a lie told with a green tick.

The remaining eight are a work item for the application and its design,
not for the platform.

### Analyzer, tests, dependency rules

```
flutter_testsmith_protocol    96 tests     analyzer clean
flutter_testsmith_engine     712 tests     analyzer clean
flutter_testsmith_cli         88 tests     analyzer clean
flutter_testsmith        273 tests     analyzer clean
figma_client     78 tests     analyzer clean   (+3 network-gated, run separately)
ai_client        20 tests     analyzer clean
example app      84 tests     analyzer clean
root tooling     22 tests
external_app      1173 tests     4 pre-existing analyzer infos, none in touched files

All dependency rules hold.
```

The three network tests really call Figma and are gated on
`FIGMA_TOKEN` + `FIGMA_FILE_KEY` being present, so the suite is green
offline and without credentials. `dart test --exclude-tags network`
forces that. Run them deliberately with `dart test -t network`; all three
pass against the live API, including a live 403 whose message does not
quote the token.

`flutter_testsmith_engine` and `figma_client` became **dev-only** path dependencies of
`flutter_testsmith`, so the defect matrix can run all three sides together.
`dev_dependencies` are never resolved for a consumer, which is why
`scripts/package_boundaries.dart` examines `dependencies:` alone — the
engine still cannot reach an application.
