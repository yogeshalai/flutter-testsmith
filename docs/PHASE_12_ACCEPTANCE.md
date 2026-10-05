# Phase 12 acceptance report

**What this is:** every major capability of the platform, marked PASS,
PARTIAL, FAIL or NOT IMPLEMENTED, with a named piece of evidence for
each.

**The rule applied throughout:** a capability is PASS only if it has been
**demonstrated by running it**. Code existing is not evidence. Where the
demonstration is a unit test the evidence names the file; where it is a
device run the evidence names the run and its output.

**Verdict up front:** this platform is **not production-ready**, and the
section at the end says what would make it so. What it *is* is a
deterministic UI validation engine whose claims are now measured rather
than asserted — which is a materially different thing from where it
started this phase, when the README said "all 11 phases complete" over a
suite with three failing tests that nothing ran.

---

## Test counts

| Package | Baseline (before Phase 12) | Now |
|---|---|---|
| `packages/flutter_testsmith_protocol` | 96 pass | **96 pass** |
| `packages/flutter_testsmith_engine` | 325 pass | **440 pass** |
| `packages/flutter_testsmith_cli` | 9 pass | **82 pass** |
| `integrations/figma_client` | 37 pass | **37 pass** |
| `integrations/ai_client` | 20 pass | **20 pass** |
| `packages/flutter_testsmith` | 176 pass | **202 pass** |
| `examples/ecommerce_app` | 7 pass, **3 fail** | **84 pass** |
| **Total** | **670 (667 pass, 3 fail)** | **961, all passing** |

Plus, on hardware: 8 full runs of the product flow, 1 seven-screen
journey, 3 fixture-driven flows, 1 smoke run and 1 emulator run.

`dart analyze --fatal-infos` over the whole workspace: no issues.
`dart run scripts/check_dependencies.dart`: all rules hold.

---

## Capability by capability

### Transport and session

| Capability | Verdict | Evidence |
|---|---|---|
| Launch, attach, handshake on a physical device | **PASS** | [device-runs §1](evidence/device-runs.md) — protocol 1.0, session id, capabilities negotiated |
| Pre-attach event recovery (ring buffer) | **PASS** | device-runs §1 — 2 recovered, 1 duplicate discarded, history complete |
| Navigation tracking | **PASS** | device-runs §2 — seven screens in order |
| UI tree inspection | **PASS** | device-runs §2 — 365 elements walked, 17 retained on `/login` |
| Tap by semantic id | **PASS** | device-runs §2 — 6 taps resolved from bounds + the ratio in the same snapshot |
| Network capture and per-screen correlation | **PASS** | device-runs §2 — 7 exchanges each attributed to the screen that made it |
| Settle detection | **PASS** | device-runs §4 — step timings; no mid-transition tree in 8 runs |
| Emulator parity | **PARTIAL** | device-runs §5 — everything structural matches; visual comparison does not port |

### API to UI validation

| Capability | Verdict | Evidence |
|---|---|---|
| Compare a mapped API field with what the UI shows | **PASS** | [api_to_ui_matrix.md](evidence/api_to_ui_matrix.md), 18 rows, real widgets through the real validator |
| Report raw / transformed / UI as structured evidence | **PASS** | `report_leakage_test.dart` "carries the raw API value"; every matrix row has the three columns |
| Detect a wrong value (price 2999 → "₹2599") | **PASS** | matrix row `DEFECT price off by 400` — api-to-ui FAIL |
| Detect a wrong enabled state (`available:false`, button live) | **PASS** | matrix rows `DEFECT availability ignored` — caught **twice**, by mapping and by rule |
| Detect truncated text ("Nike Air Max" → "Nike Air") | **PASS** | matrix row `DEFECT name truncated` |
| Detect a wrong currency symbol | **PASS** | matrix row `DEFECT currency symbol` — same number, different rendering |
| Detect a null field rendered as though present | **PASS** | matrix row `DEFECT null image still rendered` (structural, not a value comparison) |
| Zero, large, null, empty and missing values | **PASS** | matrix rows 3-7 |
| Business rules over the response | **PASS** | matrix rules rows; and on device, `product_out_of_stock` |
| Distinguish "wrong" from "could not be checked" | **PASS** | api_to_ui_matrix row `no response to compare` — reports ERROR, not FAIL, and still blocks the pass |

### API error handling

| Capability | Verdict | Evidence |
|---|---|---|
| 400 / 401 / 403 / 404 / 500 distinguished | **PASS** | [api_transport_matrix.md](evidence/api_transport_matrix.md) — real socket, real fixture server |
| Timeout distinguished from a status code | **PASS** | transport matrix — `statusCode` is null, message differs |
| Malformed body and wrong shape | **PASS** | transport matrix rows 8-9 |
| Connection refused | **PASS** | transport matrix row 10 |
| Each reaches a defined UI state | **PASS** | [ui_state_matrix.md](evidence/ui_state_matrix.md) |
| End to end, socket → screen, in one process | **PARTIAL** | proven in two halves plus a device run; see Limitation L1 |

### UI states

| Capability | Verdict | Evidence |
|---|---|---|
| loading, success, empty, error as distinct states | **PASS** | ui_state_matrix — each asserts the others are absent |
| disabled | **PASS** | ui_state_matrix `home.open_cart = false`, `products.item_789 = false` |
| unavailable, discounted, out-of-stock | **PASS** | ui_state_matrix conditional rows |
| Null and missing data render defined states | **PASS** | ui_state_matrix `null image`, `null ETA`, `missing data` |
| Asserted through the captured tree, not a widget finder | **PASS** | every row calls `UiTreeInspector` |

### Figma structural validation

| Capability | Verdict | Evidence |
|---|---|---|
| Missing element | **PASS** | [figma_defect_matrix.md](evidence/figma_defect_matrix.md) — `figma-structure` |
| Wrong element type | **PASS** | figma matrix — `figma-type` |
| Incorrect text | **PASS** | figma matrix — `figma-text`, with `text: strict` |
| Wrong position | **PASS** | figma matrix — `figma-geometry`, x out by 24px |
| Wrong dimensions | **PASS** | figma matrix — `figma-geometry`, height out by 18px |
| Incorrect spacing | **PASS** | figma matrix — reported as position on the element below the gap |
| Wrong typography | **PASS** | figma matrix — `figma-typography`, size and weight |
| Wrong colour | **PASS** | figma matrix — `figma-colour`, channel difference 165 |
| Wrong ordering | **PASS** | figma matrix — `figma-order` |
| Stale node mapping reported as tool error, not app defect | **PASS** | figma matrix — `figma-mapping` ERROR |
| Honest skips (design copy, aspect mismatch, ambiguous IMAGE) | **PASS** | figma matrix SKIP rows |
| On a real device against a real pulled design | **PASS** | device-runs §2 — 47 checks on `/product/details` |
| Portable across devices | **PASS** | device-runs §5 — unchanged on a 50%-wider, 40%-denser screen |
| **Pixel comparison against a Figma export** | **NOT IMPLEMENTED** | deliberate. [ADR-0010](adr/0010-screenshot-capture.md), risk R7 |

### Visual regression

| Capability | Verdict | Evidence |
|---|---|---|
| Deterministic across repeated runs | **PASS** | device-runs §4 — 5 runs, 0.000%, ssim 1.0000, variance zero |
| Zero false positives | **PASS** | device-runs §4 — 0 of 5 |
| Detects a seeded defect reliably | **PASS** | device-runs §4 — 3 of 3, 17.901% each time |
| Per-element gate catches what the whole-screen gate cannot | **PASS** | device-runs §4 — 0.04% of screen vs 17.9% of the element |
| Never re-baselines silently | **PASS** | `visual_validator_test.dart`; automatic mode declines and says why |
| Refuses to mix capture paths | **PASS** | device-runs §6 — real refusal message from a real run |
| Baselines per fixture | **PASS** | device-runs §3 — `product_details@product_out_of_stock.png` |
| **Baselines across device profiles** | **NOT IMPLEMENTED** | device-runs §5 — refused with both resolutions named, which is correct and not useful |

### Screenshot capture

| Capability | Verdict | Evidence |
|---|---|---|
| `screencap` path | **PASS** | every device run |
| `surface` (`repaintBoundary`) path | **PASS** | ADR-0010; measured 720x1510 on device, byte-deterministic |
| Capture path recorded and never mixed | **PASS** | device-runs §6 |
| Documented: what each excludes, coordinates, dpr, determinism | **PASS** | ADR-0010 |
| Suitable for design comparison | **NOT IMPLEMENTED**, by decision | ADR-0010 — and neither path is |

### Test selection (impact analysis)

| Capability | Verdict | Evidence |
|---|---|---|
| A single-screen change selects the right flows | **PASS** | [impact_matrix.md](evidence/impact_matrix.md) — 4 of 6 |
| A multi-screen change selects the union | **PASS** | `impact_stress_test.dart` |
| Unrelated flows excluded on positive evidence | **PASS** | impact matrix — `home`, `cart_empty` skipped |
| Full-suite fallback, with the reason that applies | **PASS** | impact matrix — four distinct causes |
| Documentation changes select nothing | **PASS** | impact matrix — last row |
| Follows navigation between screens | **NOT IMPLEMENTED** | attribution is by declaration; see Limitation L2 |

### AI boundaries

| Capability | Verdict | Evidence |
|---|---|---|
| CAN explain failures | **PASS** | `ai_boundaries_test.dart` |
| CAN suggest mappings (inert, under `suggested:`) | **PASS** | ai_boundaries_test |
| CAN suggest scenarios | **PASS** | ai_boundaries_test; and a real model produced 9 |
| CAN identify likely causes | **PASS** | ai_boundaries_test |
| CAN assign confidence to a hypothesis | **PASS** | ai_boundaries_test |
| CANNOT determine pass/fail | **PASS** | ai_boundaries_test — a model insisting everything passed leaves the run failed; the verdict is not a function of the analysis |
| CANNOT silently modify mappings | **PASS** | ai_boundaries_test — `suggested` never joins `mappings`; a confidence on an active mapping is dropped; `MappingsFile` has no serialiser |
| CANNOT silently approve a generated test | **PASS** | ai_boundaries_test — `status: approved` from the model is overwritten; the runner refuses; selection never offers it |
| CANNOT modify a user-authored test | **PASS** | ai_boundaries_test — a name collision is rejected, not overwritten |
| CANNOT convert skip/error into pass | **PASS** | ai_boundaries_test — an error blocks the pass regardless of analysis |
| No body or header ever reaches a model | **PASS** | `report_leakage_test.dart` |

28 boundary tests, every CANNOT asserted against a **deliberately
hostile** model rather than a well-behaved one.

### Generated scenarios

| Capability | Verdict | Evidence |
|---|---|---|
| Reference an existing screen | **PASS** | `generated_scenario_validity_test.dart`, over the committed files |
| Reference valid element ids | **PASS** | same |
| Reference a fixture that exists | **PASS** | same — this is the D-02 fix |
| Marked `status: proposed` | **PASS** | same |
| Refused by the runner until approved | **PASS** | verified by running one: *"is marked `status: proposed`"* |
| Never offered to test selection | **PASS** | same test |

### Security

| Capability | Verdict | Evidence |
|---|---|---|
| Redaction at capture time | **PASS** | `secret_leakage_test.dart` — the payload object holds `[REDACTED]` before any reporting code runs |
| 7 seeded secrets absent from emitted events | **PASS** | secret_leakage_test — searched as literals in serialised JSON |
| Absent from `result.json` | **PASS** | `report_leakage_test.dart` **and** device-runs §7 (real run, grepped) |
| Absent from `report.html` | **PASS** | same |
| Absent from AI input | **PASS** | report_leakage_test — bodies and headers are not sent at all |
| Nested and array secrets | **PASS** | secret_leakage_test |
| Unparseable credential-shaped body dropped whole | **PASS** | secret_leakage_test |
| Obscured fields redacted in the UI tree | **PASS** | secret_leakage_test `obscuredFieldTests`; verified on the device - `"[REDACTED]:24"`. **This was D-13, a real leak until Phase 12.** |
| **A secret in a URL query string** | **FAIL** | secret_leakage_test asserts the leak, deliberately. See Limitation L3 |

---

## Discovered defects

Thirteen, all found by running something or by reading its real output -
none by reading source.

| # | Defect | Found by | Severity |
|---|---|---|---|
| D-01 | Three example tests failing since Phase 6: `TextButton` cast as `FilledButton`, and a price that now renders twice | running the suite | **high** — the README claimed eleven complete phases over a red suite |
| D-02 | All 7 committed proposals declare preconditions nothing could arrange; one names a field the API does not have | reading them against the fixture server | **high** — approving one would have added a test that passes against the default state |
| D-03 | `AppScope.of(context)` called from `initState` in five screens | the UI state matrix | high (new code) |
| D-04 | `UiTreeInspector` reports `enabled: null` for a `ListTile`, so a rule asserting `enabled: false` fails on a correct app | the UI state matrix | medium |
| D-05 | Tapping an element below the fold dispatched a tap outside the viewport; Android delivered it to nothing and the run failed four steps later | the seven-screen journey on device | **high** |
| D-06 | A right-aligned text's `x` was compared in projected space; a pixel-perfect element reported 50.8px out | the journey on device | medium |
| D-07 | A file whose test ids are all interpolated looked attributable and selected **0 of 6** flows | `testsmith impact --changed` | **high** — a missed test is a regression nobody looks for |
| D-08 | The navigation bar differed from the baseline by a constant 723px on every run — a third of the tolerance budget | investigating a constant 0.065% | medium |
| D-09 | A visual baseline is keyed by screen alone, so a screen that legitimately differs under another fixture cannot have one | `product_out_of_stock` on device | medium |
| D-10 | No CI workflow existed at all | looking for one | **high** — the root cause of D-01 |
| D-11 | `maxTokens: 2048` truncated generation, which surfaced as "failed to generate JSON" | running `testsmith generate` | low |
| D-12 | Per-element visual regions include elements belonging to routes underneath the current one, so a "worst element" list can name something not on screen | reading a device run's output | low |
| | *(**fixed** during external validation, and worse than described: the covered route's widgets are in the tree with real bounds and `visible: true`, so `ui-presence` saw them too. See [EXTERNAL_APP_VALIDATION.md](EXTERNAL_APP_VALIDATION.md).)* | | |
| D-13 | **The UI tree carried an obscured field's contents in plaintext.** `TextField #login.password "SEEDED_PASSWORD_c41e77b0"` - on a screen showing dots. The tree is emitted as an event and written by `testsmith inspect --json` | reading a real capture from the device | **high** |

## Fixed in this phase

D-01 through D-11 and D-13 — twelve of thirteen, each with a test that
fails without the fix.

**D-12 was fixed in the external-validation milestone**, where it turned
out to be a capture defect rather than a labelling one: a covered
route's widgets stay in the tree with real bounds, reporting
`visible: true`.

---

## Remaining limitations

**L1 — `flutter_test` cannot drive a real socket.** Initialising the
Flutter test binding replaces `HttpOverrides.global` with one answering
every request with a canned 400, and a request issued from `initState`
is never delivered — measured: a `MockApiServer` bound inside a widget
test never sees the connection and the test hangs until it times out.
The transport chain is therefore proven in a binding-free file over a
real socket, the UI chain in widget tests, and the join on a device.
Three pieces of evidence rather than one.

**L2 — Test selection does not follow navigation.** Attribution is by
what a file *declares* — a route constant, a `TestKey`, the `screen:` a
config names. If ProductDetails were changed so that its Add to Cart
pushed the wrong route, a cart-only flow entering the cart another way
would still pass. A journey flow covers this in practice; the analysis
does not understand the edge.

**L3 — A credential in a URL is not redacted.** Redaction works on
headers and on decoded JSON; a query parameter is neither. Recorded as a
deliberately passing test that asserts the leak, so that fixing it makes
a test fail and the documentation gets updated.

**L4 — Visual baselines are per device resolution.** Correctly refused
across devices rather than resampled, which is right and not useful. The
per-fixture variant added this phase is the mechanism to extend.

**L5 — Ignore regions belong to a capture path, not a screen.**
Switching a screen from `screencap` to `surface` and changing nothing
else silently masks 105 rows of real content. Nothing warns.

**L6 — No scroll step.** An element below the fold cannot be tapped. The
platform now refuses clearly instead of tapping nothing, but a flow must
reach such an element another way.

**L7 — One anchor per screen.** `textAnchor` is declared per screen; a
screen mixing left- and right-anchored text cannot be expressed. Figma's
own `textAlign` cannot be used to infer it — measured: it describes
glyphs inside the box, not how the box is anchored, and reading it as an
anchor reported a pixel-perfect element as 5.7px out.

**L8 — Platform views are invisible to the surface capture.** A
`WebView` or map is a hole in the image, and nothing warns.

**L9 — One API response per screen.** `ValidationContext.response`
returns the first completed exchange. A screen making two calls can only
be validated against one.

**L10 — The Checkout Figma spec is hand-authored.** No Figma file exists
for that screen and no token is configured. It is in the exact shape
`testsmith figma pull` writes, so it exercises the validators honestly, but
it does not establish that the screen matches a designer's intent. Said
in the file itself.

**L11 — Android only.** No iOS device has been run. Nothing in the
engine is Android-specific except `AdbDeviceController`, but that is an
assertion, not a measurement.

**L12 — Single flow per invocation.** `testsmith run` takes one flow file.
There is no suite runner, no parallelism, no retry, no sharding.

---

## API → UI validation matrix

Generated by the run that produced it, in
[api_to_ui_matrix.md](evidence/api_to_ui_matrix.md). Summary:

| Class | Rows | Result |
|---|---|---|
| Correct rendering (normal, zero, large, null, empty, missing) | 7 | 5 PASS, 2 FAIL where the screen genuinely disagrees with the API |
| Conditional UI driven by rules | 4 | 4 PASS |
| Seeded defects | 7 | **7 FAIL — every one caught** |

Every failing row carries the raw API value, the declared
transformation, what it should have produced, and what the UI showed.
**No AI is involved in any of these verdicts**, and there is no code
path by which it could be.

---

## Is it production-ready?

**No.** Three things are missing, and none of them is a detail:

1. **No suite runner.** One flow per invocation, no parallelism, no
   retry, no sharding, no CI job that runs flows on a device. What
   exists is a tool a person drives.
2. **Visual regression is single-device.** A baseline belongs to one
   resolution. Any team with two phone models cannot use it as it
   stands.
3. **One application has been tested.** The example was written
   alongside the platform, by the same hand, which is the weakest
   possible evidence of generality. Every semantic id is where the
   platform wants it.

What it **is**, with evidence: a deterministic validation engine whose
API-to-UI, rules, structural-design and visual-regression checks all
detect seeded defects reliably and repeatably on real hardware, whose
AI layer provably cannot reach a verdict, and whose secrets provably do
not reach a report.

---

## Recommendation for Phase 13

**Run this platform against an application nobody on this project
wrote.**

Every capability above is measured, and all of it is measured against
one application built alongside the tool. That is the largest untested
assumption in the repository, and it dwarfs the individual limitations:

- Does the UI tree retain the right nodes on a screen built by someone
  with different habits?
- Does `enabled` work on the widgets they actually use? D-04 found
  `ListTile` missing after one afternoon with one new screen.
- How many mappings does a real screen need before it is worth it?
- Does `waitForSettle` return on a screen with a shimmer placeholder or
  a looping animation? Nothing here has one.

Concretely, in order:

1. **Adopt an existing internal Flutter app.** Instrument it, write
   mappings for three screens, and run. Count what breaks.
2. **Baselines per device profile** — the same variant mechanism as
   fixtures, keyed by resolution and ratio. L4, and the blocker for
   more than one phone.
3. **A suite runner** — many flows, one report, wired to
   `testsmith impact` so CI runs what a change makes worth running.
4. **A scroll step** — L6, which the journey flow already had to work
   around.

Explicitly **not** next, and still out of scope: cloud backend,
dashboard, autonomous exploratory AI, device farm, multi-user, and a
release-mode WebSocket transport. None of them makes the platform more
trustworthy, and trustworthiness is what it is short of.
