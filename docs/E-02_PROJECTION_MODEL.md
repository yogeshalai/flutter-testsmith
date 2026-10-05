# E-02 — The projection model

How a design coordinate becomes a device coordinate, and why the obvious
answer was wrong.

---

## 1. The problem

The first implementation projected a design onto a device by scaling:

```dart
scale = viewportWidth / designWidth;      // 384 / 402 = 0.95522
expected = designCoordinate * scale;
```

That is correct if a design is a picture. A design is not a picture, it
is a layout, and the difference shows up as an error that **grows with
distance from the origin** — because scaling multiplies the coordinate,
and a coordinate far from the origin is a big number.

The real `external_app` Login run made it unmissable. Same screen, same run,
top to bottom:

| Element | Design y | Scaled expectation | App | Invented error |
|---|---|---|---|---|
| `login.card` | 322 | 307.6 | 302 | 5.6px |
| `login.divider_label` | 552 | 527.3 | 543 | 15.7px |
| `login.google_button` | 591 | 564.5 | 582 | 17.5px |
| `login.policy_text` | 675 | 644.8 | 708.3 | 63.6px |

No tolerance can fix that. A tolerance wide enough to absorb 63.6px
would absorb every real defect on the screen.

**The rule the model now rests on, in one sentence:**

> A design coordinate is not a scalable quantity. It is an inset from an
> anchor, and a length is a length.

`x = 329` in a 402-wide frame does not mean "82% of the way across". It
means "20px in from the right", and those are the same number only at the
width the design was drawn at. A 20px gutter is 20px on a narrower
screen. A 48px button is 48px tall. Figma's own auto-layout behaves
exactly this way: resizing a frame does not rescale its padding, its
item spacing, or a child whose size is fixed.

---

## 2. Evidence from the real application

### 2.1 The anchors are declared, not inferred

The investigation started by asking what the real Login frame
(`909:1` of `<redacted>`) actually says. The first answer
was a trap:

```
semantic id              node        constraints (v/h)
login.skip_button        909:145    TOP/LEFT
login.policy_text        909:141    TOP/LEFT
login.card               909:16    TOP/LEFT
```

Every node reports `LEFT/TOP` — including the one the designer pinned to
the **right** edge. Figma leaves `constraints` at its default for
children of an auto-layout frame and ignores it. Reading it there would
have produced a confident, wrong answer for every element on the screen.

The real statement is in the parent's auto-layout:

```
--- skip_button (909:145)
    parent 909:144 'Frame 43007'  layoutMode=HORIZONTAL
           primaryAxisAlignItems=MAX   paddingRight=20
    insets left=329.0 right=20.0
--- policy_text (909:141)
    parent 909:15 'Frame 427318357'  layoutMode=VERTICAL
           counterAxisAlignItems=CENTER
    insets left=28.0 right=28.0   centre-offset=0.0
```

`primaryAxisAlignItems: MAX` is Figma saying *end-anchored*.
`counterAxisAlignItems: CENTER` is Figma saying *centred*. And for the
frame's own absolutely positioned children, `constraints` **is**
authoritative, and there it carries real information:

```
909:3  Logo                   constraints=CENTER/TOP
917:1 Frame 427318352        constraints=CENTER/BOTTOM
```

A genuinely bottom-anchored row, in the same file.

### 2.2 The anchors are right

Under the correct invariant, elements the old model reported as broken
match **exactly**:

| Element | Anchor (derived) | Design invariant | App | Δ |
|---|---|---|---|---|
| `login.skip_button` | end (horizontal) | right inset 20 | right inset 20 | **0** |
| `login.policy_text` | centre | centre offset 0 | centre offset 0 | **0** |
| `login.card` | stretch | insets 20 / 20 | insets 20 / 20 | **0** |

### 2.3 A length is a length

Every `FIXED` dimension in the frame matches the running app exactly,
unscaled — and matches nothing under scaling:

| Element | Sizing | Design | App | Identity | Scaled |
|---|---|---|---|---|---|
| `login.continue_button` height | FIXED | 48 | 48 | **exact** | 45.9 ✗ |
| `login.google_button` height | FIXED | 48 | 48 | **exact** | 45.9 ✗ |
| `login.divider_label` height | FIXED | 19 | 19 | **exact** | 18.1 ✗ |
| `login.policy_text` width | FIXED | 306 | 306 | **exact** | 292.3 ✗ |

Four for four. This is not fitting a curve to the app: it is what a
length means.

### 2.4 And some lengths are not the design's to state

`HUG` means "as big as the content". Two text engines produce two
different boxes from one string, so a hugged dimension compares font
metrics rather than layout. The card's height is `HUG` and differs by
12px between the design and the app for exactly that reason. It is no
longer compared, and the report says why.

---

## 3. Principles

1. **Do not scale a coordinate.** Compare the quantity the declared
   anchor holds invariant: a leading inset, a trailing inset, or an
   offset from the centre.
2. **A length is a length** unless the design says it is a proportion
   (`SCALE`) or is content-determined (`HUG`).
3. **Read the anchor from the right place.** Auto-layout alignment for a
   child of an auto-layout frame; `constraints` for an absolutely
   positioned one. Never the other way round.
4. **Measure both sides the same way**, against the nearest ancestor the
   design declares *and* the screen matched.
5. **Where the design does not say, do not guess.** Skip, with the reason
   in the message.
6. **Except where there is nothing to guess about.** The ambiguity in
   "unknown" is only ever about how something behaves *when the frame
   resizes*. If the reference is the same size on both sides, every
   anchor gives the same answer and a length is simply a length, so the
   comparison runs.

---

## 4. Supported transformations

`AnchorProjection` ([anchor_projection.dart](../packages/flutter_testsmith_engine/lib/src/validation/anchor_projection.dart))
works one axis at a time, so an element that fills horizontally and is
fixed vertically — the commonest real shape — is treated correctly on
each axis.

### Position, by anchor

| Anchor | Figma source | Compared quantity |
|---|---|---|
| `start` | `primaryAxisAlignItems: MIN`/absent, `layoutAlign: MIN`, `constraints: LEFT`/`TOP` | leading inset |
| `end` | `MAX`, `constraints: RIGHT`/`BOTTOM` | trailing inset |
| `centre` | `CENTER`, `constraints: CENTER` | offset from the reference centre |
| `stretch` | `layoutAlign: STRETCH`, `constraints: LEFT_RIGHT`/`TOP_BOTTOM` | leading inset (both edges pinned) |
| `proportional` | `constraints: SCALE` | leading inset × the reference ratio |

### Size, by sizing

| Sizing | Figma source | Expected length |
|---|---|---|
| `fixed` | `layoutSizing*: FIXED`, or a one-sided constraint | the design's own length, unscaled |
| `fill` | `FILL`, `layoutAlign: STRETCH`, `layoutGrow > 0`, `LEFT_RIGHT`/`TOP_BOTTOM` | the matched reference's extent, less this element's insets |
| `proportional` | `SCALE` | the design's length × the reference ratio |
| `hug` | `HUG` | **not compared** |

### The reference

Positions and fills are measured against the **nearest ancestor the
design declares and the screen matched**. An unmapped Figma group has no
counterpart to measure against, so the walk continues past it; when
nothing above is matched, the reference is the frame and the viewport.

This is why matching now happens in a first pass and comparison in a
second: measuring an element against the frame merely because its
container had not been reached yet would make the answer depend on
document order.

---

## 5. Unsupported and unknown

| Case | Behaviour |
|---|---|
| `primaryAxisAlignItems: SPACE_BETWEEN` | anchor `unknown`. Where a child lands depends on how many siblings there are and how wide each turned out, which is not a property of the child. |
| `counterAxisAlignItems: BASELINE` | anchor `unknown`. Baseline alignment says nothing about the box. |
| A spec with no layout metadata (pre-E-02, or a node Figma gives none for) | `unknown`. Compared anyway when the reference did not resize (principle 6); skipped with the two extents named when it did. |
| A `fill` element whose design insets already exceed the viewport | skipped: the design does not describe this viewport. |
| A text element whose design declares no anchor | falls back to the per-screen `textAnchor` setting — the escape hatch that predates this model, kept for exactly this case. |

Nothing falls back to scaling.

---

## 6. Figma metadata used

Read per node: `layoutSizingHorizontal`, `layoutSizingVertical`,
`layoutAlign`, `layoutGrow`, `constraints.horizontal`,
`constraints.vertical`, `clipsContent`.

Read from the parent: `layoutMode`, `primaryAxisAlignItems`,
`counterAxisAlignItems`.

All of it comes from the same `GET /v1/files/{key}/nodes` response the
platform already fetched; no new endpoint was needed.

Derivation lives in
[layout_semantics.dart](../integrations/flutter_testsmith_figma/lib/src/layout_semantics.dart)
and is asserted against the real frame by
`integrations/flutter_testsmith_figma/test/layout_semantics_test.dart`.

---

## 7. Safe area

Made explicit, and deliberately not assumed.

- **The device's inset is measured.** The SDK reads `FlutterView.padding`
  at capture and reports it as `UiSnapshot.safeArea`, converted to
  logical pixels. On the test device that is `t24.0`. There is no
  universal status-bar height, and a constant would be wrong on every
  device except the one it came from.
- **The design's inset is declared or absent.** Figma publishes no
  safe-area metadata: a frame is 874pt tall and says nothing about how
  much of that the designer intended as chrome. A screen may declare
  `designSafeAreaTop:` in its `figma:` block; there is no default.
- **When both are known**, the comparison happens in content space — each
  side measured from below its own inset — so an implementation that
  positions correctly relative to the safe area agrees with a design that
  does the same.
- **When the design does not declare one**, the comparison runs
  unadjusted and the device's inset is stated in the report, so a reader
  can see the cause of any offset rather than guessing at it.

The Login screen declares none, which is why `login.background`
(`vertical leading inset 24.0 vs 60.0`) and `login.skip_button` still
disagree. Declaring a number that made them agree would be fitting the
configuration to the result.

---

## 8. Clipping

Implemented from the design's own semantics, not by clamping.

An element is cut down only when an **ancestor that actually clips**
(`clipsContent: true`) would cut it. The clip box is carried down the
walk, so a nested clipping frame clips its own subtree and a design that
deliberately bleeds past a non-clipping frame is left alone. An element
entirely outside its clip is dropped — it is on the canvas but not on the
screen.

The unclipped box is kept as `FigmaElement.unclippedRect` so a report can
say the design overflows rather than silently comparing against a box
nobody drew.

On the real Login frame (`clipsContent: true`), the background artwork is
authored 542.7 wide inside a 402-wide frame; 140px of it is not on the
screen. It is now normalised to 402 wide, with the 542.7 recorded.

---

## 9. Test matrix

`packages/flutter_testsmith_engine/test/design_projection_test.dart` — 24 cases, each
documenting why its expected transformation is correct.

| # | Case | What it fixes |
|---|---|---|
| 1 | same-size viewport | proves the model transforms nothing when there is nothing to transform |
| 2, 4 | proportional position and size (`SCALE`) | the one case where scaling is what the design asked for |
| 3 | fixed horizontal padding | the commonest real case; scaling reported a correct 20px gutter as 0.9px out |
| 5 | fixed height | scaling reported a correct 48px button as 2.1px short |
| 6 | proportional height | as case 2, vertically |
| 7 | top anchoring | distance from the top |
| 8 | bottom anchoring (+ a wrong-edge case) | a bottom-pinned element's *top* coordinate must change when the viewport height does |
| 9 | centre anchoring (+ a not-centred case) | offset from the centre |
| 10 | right anchoring | distance from the right edge |
| 11 | safe-area inset (declared, and absent) | content space when both are known; unadjusted and reported when not |
| 12 | mixed fixed + proportional | each axis by its own rule |
| 13, 15 | design overflow, aspect mismatch | a fill that cannot fit is a skip, not a negative expectation |
| 14 | clipping | already applied by the normaliser, so a clipped box projects normally |
| 16 | unknown metadata (anchor, sizing, hug) | skip with a reason — and compare anyway when the reference did not resize |
| — | stretch | both edges pinned, so the size gives |

---

## 10. Regression results

### The Flutter-side defect matrix — the one that matters

All thirteen seeded defects, before and after:

```
case                                            before     after  validator
wrong width                                       FAIL      FAIL  figma-geometry
wrong height                                      FAIL      FAIL  figma-geometry
wrong position                                    FAIL      FAIL  figma-geometry
wrong colour                                      FAIL      FAIL  figma-colour
wrong font size                                   FAIL      FAIL  figma-typography
wrong font weight                                 FAIL      FAIL  figma-typography
missing node                                      FAIL      FAIL  figma-structure
unexpected node                                   FAIL      FAIL  figma-unexpected
hierarchy mismatch                                FAIL      FAIL  figma-hierarchy
ambiguous identity (duplicate test id)           ERROR     ERROR  figma-identity
wrong corner radius                               FAIL      FAIL  figma-radius
wrong gap between two adjacent elements           FAIL      FAIL  figma-spacing

verdict changes: 0
```

**No seeded defect became a pass.** The control case still passes, so the
matrix is not satisfied by a comparison that fails everything. The two
tolerance cases still behave: a 3px drift passes at `positionPx: 4` and
fails at `positionPx: 1`.

### The design-side defect matrix

`docs/evidence/figma_defect_matrix.md` — every verdict unchanged. Three
messages changed wording, from a bare axis letter to the quantity that
disagrees:

```
- "checkout.total" ... x is 268.0px but the design projects to 244.0px
+ "checkout.total" ... horizontal leading inset is 268.0px but the design specifies 244.0px
```

### Two verdicts that did change, and were investigated

Both were in the *example* app's design-side matrix, and both were
caused by over-strictness rather than by the anchor model:

| Case | Became | Why | Resolution |
|---|---|---|---|
| wrong dimensions | SKIP | its committed spec predates layout metadata, so sizing was `unknown` | principle 6: with no resize there is nothing to be ambiguous about, so the length is compared |
| incorrect spacing | PASS | same, for the vertical position | same |

Both are FAIL again, and both are now covered by projection cases
asserting each direction — compared when the reference did not resize,
skipped with both extents named when it did.

### A change made and then reverted

`input tap` sends a DOWN and an UP in the same instant, and a
press-and-hold is generally more reliable. It was implemented, tested,
and then **reverted**, because the flake it was meant to explain turned
out to have a different cause entirely (§11) and no evidence in this
project supported the change. A comment claiming a measurement that did
not happen is worse than the original code.

---

## 11. Real-device result

Samsung SM-M127G, Android 13, 384 × 805.3 logical, device inset `t24.0`.
Same real Figma frame, same real application, same tolerances — every
one a platform default, none loosened.

```
                     before      after
figma checks passed      39         43
figma checks failed      11          8
figma errors              0          0
figma skips              10         10
```

**Three projection-induced false failures removed**, and the character of
what remains changed completely:

| Element | Before | After |
|---|---|---|
| `login.mobile_field` | width 5.6 out, height 4.2 out | **passes** |
| `login.country_code` | x 4.8 out | **passes** |
| `login.continue_button` | y 4.7 out, width 5.6 out | **passes** |
| `login.skip_button` | x, y, width, height all out | only vertical remains |
| `login.card` | y out, height 27.3 out | only y; height is `HUG` and no longer compared |

The eight that remain are genuine disagreements between this application
and this design:

| Element | Difference | Kind |
|---|---|---|
| `login.policy_text` | reads "…Privacy Policy"; design says "…Privacy Policy **and Content Policy**" | a real copy defect |
| `login.policy_text` | font weight 400, design says 500 | a real style difference |
| `login.policy_text` | vertical inset 708.3 vs 675 | the app pins it to the bottom; the design flows it |
| `login.card` | vertical inset 302 vs 322 | the content above it differs in height |
| `login.divider_label` | vertical 241 vs 230, width 302 vs 314 | an 8px spacing difference above it; a fixed 314 rendered as 302 |
| `login.google_button` | vertical 280 vs 269 | the same accumulated 11px |
| `login.skip_button` | vertical centre offset 12.8 out | the design assumes a taller status area than this device has |
| `login.background` | inset 24 vs 60, 384×781 vs 402×814 | the app fits it to the screen; the design fixes it at 402×814 from y=60 |

None of them is a projection artefact, and none has been tuned away.

---

## 12. Remaining limitations

1. **A frame taller than the viewport still skips vertical position** at
   the screen level, on the existing aspect guard. With anchors this is
   no longer about arithmetic; it is that most of a 2597pt frame is below
   the fold and the captured bounds are for one scroll position. The
   guard is now imprecise rather than wrong, and should become a
   scroll-aware comparison.
2. **`SPACE_BETWEEN` is unresolved.** Resolving it needs the sibling set
   and each sibling's realised size, which is a layout pass rather than a
   per-element projection.
3. **Nested auto-layout is not simulated.** Each element is projected
   against its nearest *matched* ancestor, not by re-running Figma's
   layout engine down the tree. Where the intervening frames are
   unmapped, their contribution is whatever the design measured, which is
   right until one of them would itself have resized.
4. **A fixed-size child of a frame that does not stretch will overflow a
   narrower viewport**, and the design is silent about what should happen
   — `login.background` is exactly this. The platform reports the
   difference rather than deciding for the designer.
5. **The design's safe area must be declared by hand.** Figma does not
   publish one. An iOS/Android device-frame convention could be inferred
   from the frame size, and deliberately is not.
6. **`SCALE` is untested against a real file.** No node in this design
   uses it; the two cases covering it are synthetic, and say so.
