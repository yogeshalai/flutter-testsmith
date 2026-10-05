# Phase 12 - Hardening and Acceptance

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` or `superpowers:executing-plans`
> to work through this task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Prove the eleven shipped phases work end to end against a
realistic application, and write down - with evidence - exactly where
"implemented" and "production-ready" are not the same thing.

**Architecture:** No redesign. Phase 12 adds three things the existing
architecture already anticipated but never grew: a **fixture scenario
selector** on the mock API (so a flow can name the API state it needs), an
**in-app screenshot RPC** (the `repaintBoundary` arm of `ScreenshotSource`,
which the protocol has declared since Phase 1 and nothing has ever
emitted), and a **defect matrix harness** that drives the real validators
over the real widgets. Everything else is application code, fixtures,
specs, tests and measurement.

**Tech stack:** Dart 3.12 workspace; Flutter for `flutter_testsmith` and the
example app; `package:image` for pixel work; `adb` for device control;
Android 13 (SM-M127G, serial `RZ8T11QETWM`) and the `mytest_api33` AVD.

**Spec:** the Phase 12 brief, restated in full as §0 below.

---

## Global constraints

Copied verbatim from the brief; every task inherits them.

- **Do NOT redesign the architecture unless a real technical limitation
  requires it.** If a finding requires architectural change, STOP and
  report it before modifying the architecture.
- **Do not use AI to determine pass/fail.** The deterministic engine
  decides; AI explains.
- **Do NOT claim pixel-perfect Figma comparison.** The existing
  distinction between Figma *structural* validation and *visual*
  comparison must remain.
- **A capability is PASS only if it has been demonstrated with a real
  test.** Code existence is not evidence.
- **Do not say "production ready"** unless the acceptance evidence
  supports it.
- **Out of scope, deliberately:** cloud backend, dashboard, autonomous
  exploratory AI, device farm, multi-user system, release-mode WebSocket
  transport.
- Screen id `/product/details` and semantic ids `home.open_product`,
  `product.name`, `product.price`, `product.add_to_cart`,
  `product.image`, `product.description`, `product.unavailable`,
  `product.discount_badge` **must not change**: the committed Figma
  spec, the committed visual baseline and two committed flows all bind
  to them.
- The ProductDetails **layout must not change**. Its screenshot baseline
  was recorded on the physical device; changing a margin invalidates the
  one piece of real visual evidence the repository holds.
- `flutter_testsmith_engine` must never import Flutter; `flutter_testsmith` must never import
  `flutter_testsmith_engine`. `dart run scripts/check_dependencies.dart` enforces
  both and must stay green.

---

## §0 The brief, as acceptance criteria

| # | Requirement | Task |
|---|---|---|
| 1 | Realistic 7-screen ecommerce app with loading/error/empty/null/conditional states | T3, T4 |
| 2 | Test matrix: API success variants, API errors, UI states - with the catching test named | T6, T7 |
| 3 | Seeded API→UI defects, each caught deterministically, reported with raw/transformed/UI/mapping/validator/status/evidence | T5, T6 |
| 4 | Realistic Figma spec for ProductDetails and Checkout; eight seeded design defects | T8 |
| 5 | Screenshot capture architecture investigated; implemented if safe, limitation documented if not | T9 |
| 6 | Repeated visual regression, measured: raw pixel, perceptual, false positives, timing | T13 |
| 7 | Impact analysis stressed on the full app, including multi-screen change and full-suite fallback | T10 |
| 8 | AI boundaries proven by automated test - five CANs, five CANNOTs | T11 |
| 9 | Generated scenarios reference real screens/ids/flows/fixtures; committed proposals fixed | T2, T12 |
| 10 | Seeded secrets never reach events, result.json, HTML or AI input; redaction at capture time | T5, T14 |
| 11 | Physical device run of the important flows, plus the same core flow on the AVD | T13 |
| 12 | `docs/PHASE_12_ACCEPTANCE.md` with PASS/FAIL/PARTIAL/NOT IMPLEMENTED per capability | T15 |

---

## File structure

### New - application (`examples/ecommerce_app/lib/`)

| File | Responsibility |
|---|---|
| `api/api_client.dart` | One `HttpClient` wrapper. Owns the base URL, the `Authorization` header, timeouts and JSON decoding. The only place the app talks to the network, so the only place a credential can be seeded. |
| `api/models.dart` | `Product`, `CartLine`, `Cart`, `Order`, `Session`. Null-tolerant `fromJson` for every one - a missing or null field must produce a defined UI state, not an exception. |
| `api/defects.dart` | `Defects`, the seam that injects a deliberate bug. Defaults read `bool.fromEnvironment`, so a device run seeds with `--dart-define`; a widget test assigns `Defects.current` directly. |
| `app.dart` | `MaterialApp`, routes, the navigator observer, the session holder. |
| `screens/login_screen.dart` | `/login` - form, validation, loading, 401 error. |
| `screens/home_screen.dart` | `/home` - greeting, cart badge, two ways forward. Keeps `home.open_product`. |
| `screens/product_list_screen.dart` | `/products` - list, empty, error, retry, out-of-stock and discount badges. |
| `product_details_screen.dart` | `/product/details` - **unchanged layout**, extended only to navigate to the cart. |
| `screens/cart_screen.dart` | `/cart` - lines, totals, empty, error, disabled checkout. |
| `screens/checkout_screen.dart` | `/checkout` - address, card, CVV, OTP, place order, 400/402 errors. |
| `screens/order_success_screen.dart` | `/order/success` - order id, ETA, null-ETA fallback. |
| `widgets/async_view.dart` | One place that renders loading / error / empty / data, so every screen's four states are the same four states. |

### New - fixtures, mappings, designs

| Path | Responsibility |
|---|---|
| `mock_api/scenarios/default.json` | Every route's happy path. Every other scenario inherits it. |
| `mock_api/scenarios/*.json` | One named API state each: `product_out_of_stock`, `product_discounted`, `product_null_fields`, `product_missing_price`, `product_zero_price`, `product_large_values`, `products_empty`, `cart_empty`, `api_400`, `api_401`, `api_403`, `api_404`, `api_500`, `api_timeout`, `api_malformed`. |
| `mappings/*.yaml` | One per screen with an API: product_list, product_details (exists), cart, checkout, order_success. |
| `figma/checkout.json` | Hand-authored normalised spec, in the exact shape `testsmith figma pull` writes. |
| `tests/*.yaml` | One flow per scenario worth running end to end. |

### New - platform

| Path | Responsibility |
|---|---|
| `packages/flutter_testsmith_engine/lib/src/fixtures/scenario.dart` | `ApiScenario` / `ScenarioRoute`: parse a scenario file, resolve inheritance, answer "what does `GET /products/123` return here?". No `dart:io`. |
| `packages/flutter_testsmith/lib/src/capture/screen_capture.dart` | `captureSurface()` - the `repaintBoundary` capture path, behind the `ext.mytest.screenshot` RPC. |
| `packages/flutter_testsmith_engine/lib/src/device/surface_screenshot.dart` | Engine-side decoder for that RPC's reply. |

### Modified

| Path | Change |
|---|---|
| `packages/flutter_testsmith_engine/lib/src/dsl/test_flow.dart` | New top-level key `fixture:`. |
| `packages/flutter_testsmith_engine/lib/src/validation/validators.dart` | API→UI failures carry the **raw** value and the transformation name as structured evidence, not only in prose. |
| `packages/flutter_testsmith_cli/lib/src/mock_api_server.dart` | Serve a named scenario; record every exchange; support delay, raw body and arbitrary status. |
| `packages/flutter_testsmith_cli/lib/src/commands/run_command.dart` | `--fixture`, and refuse a flow naming a scenario that does not exist. |
| `packages/flutter_testsmith_engine/lib/src/ai/test_generator.dart` | Evidence gains `fixturesThatExist`; a proposal naming an unknown fixture is rejected. |
| `examples/ecommerce_app/test/widget_test.dart` | Fix the three tests that have been failing since Phase 6. |

---

## Tasks

### T1 - Baseline: record what is actually true today

Before changing anything, measure it. This is the control for every later
claim.

- [ ] Run every suite and record the counts.
      `dart run scripts/check_dependencies.dart`, then `dart test` in
      `flutter_testsmith_protocol`, `flutter_testsmith_engine`, `flutter_testsmith_cli`, `figma_client`,
      `ai_client`, and `flutter test` in `flutter_testsmith` and
      `examples/ecommerce_app`.
- [ ] Record failures verbatim in `docs/evidence/T1-baseline.md`.

**Known going in (found during survey, must be confirmed):**
`examples/ecommerce_app` has **3 failing tests** -
`tester.widget<FilledButton>(find.byKey(TestKey('product.add_to_cart')))`
throws `type 'TextButton' is not a subtype of type 'FilledButton'`. Phase 6
changed the widget when it implemented the design and did not update the
test. A `find.text('Rs 2,999')` assertion fails for the same reason the
price now renders twice (card total + price).

---

### T2 - Fix the broken example tests, and the broken proposals

Two committed defects, both of which make a "green suite" claim false.

- [ ] **D-01** Update `widget_test.dart` to read the widget that is
      actually there. Assert on `enabled` the way the platform does -
      through `UiTreeInspector`, not through a widget cast - so the test
      stops breaking every time the button style changes.
- [ ] Run: `cd examples/ecommerce_app && flutter test`. Expected: all pass.
- [ ] **D-02** Every file in `tests/proposed/` declares a precondition
      (`API returns HTTP 404`, `"discount":120`, `"highlights":[]`) that
      nothing can arrange: the mock API serves one static file and the
      flow language cannot ask for anything else. They are unrunnable
      even after a human approves them. Leave them **in place and
      failing loudly** until T4 gives them something to name, then
      regenerate against real fixtures in T12.
- [ ] Commit.

---

### T3 - Fixture scenarios

The mechanism the whole matrix depends on. Additive: the mock API and the
flow language both already exist, this gives them a selector.

- [ ] Write `packages/flutter_testsmith_engine/test/scenario_test.dart` first:
      a scenario inherits `default`, overrides one route, rejects an
      unknown key, refuses a route string that is not `METHOD /path`, and
      round-trips `status`, `body`, `rawBody`, `delayMs`, `headers`.
- [ ] Implement `ApiScenario` in `flutter_testsmith_engine/lib/src/fixtures/scenario.dart`.
      `rawBody` and `body` are mutually exclusive - a scenario that sets
      both is a file that cannot be served unambiguously.
- [ ] Add `fixture:` to `TestFlow`, with a test that an unknown top-level
      key still fails and that `fixture:` survives a round trip.
- [ ] Teach `MockApiServer` to serve a scenario, delay a response, and log
      every exchange with its status.
- [ ] `testsmith run` resolves the flow's fixture, and **refuses to run** if
      the named scenario file is absent - the same reasoning as
      `status: proposed`: a test that silently runs against the wrong
      state is worse than one that does not run.
- [ ] Commit.

---

### T4 - The application

Seven screens. Not pretty; realistic where it matters.

- [ ] `api/models.dart` with null-tolerant parsing, and unit tests for
      every degenerate input: absent field, explicit `null`, `0`, a very
      large number, wrong type, empty list.
- [ ] `api/api_client.dart`: seeds `Authorization: Bearer <token>` on
      every authenticated call, a `X-Session-Token` header, and posts a
      card number, CVV and OTP at checkout. These are the T14 canaries.
- [ ] `widgets/async_view.dart`: `loading | error | empty | data`, one
      implementation, so "empty" cannot accidentally render as "loading"
      on one screen and not another.
- [ ] The seven screens, each with its semantic ids.
- [ ] `app.dart` wires the routes and keeps `TestSdk.navigatorObserver`.
- [ ] Widget tests per screen for each of its states.
- [ ] **Verify ProductDetails is byte-identical**: re-run the committed
      visual baseline comparison on the device. If it moved, the layout
      changed and that is a bug in this task.
- [ ] Commit.

---

### T5 - Structured evidence, and the defect seam

- [ ] `Defects` class: `priceOffBy`, `ignoreAvailability`, `truncateName`,
      `showDiscountWhenZero`, `wrongCurrencySymbol`, `cartTotalIgnoresFee`,
      `renderImageWhenNull`. Defaults from `bool.fromEnvironment` /
      `int.fromEnvironment`, so a device run seeds with `--dart-define`.
- [ ] Extend `ApiToUiValidator`'s failure evidence with
      `Evidence(kind: 'apiValue', …)` and
      `Evidence(kind: 'transformation', …)`. The brief requires the raw
      API value in the *report*; today it exists only inside a prose
      message, which no consumer can read. Update `reporting_test.dart`.
- [ ] Commit.

---

### T6 - API→UI defect matrix

`examples/ecommerce_app/test/platform/api_to_ui_matrix_test.dart`.

Drives the **real** `UiTreeInspector` over the **real** widgets and feeds
the resulting `UiSnapshot` plus a real `ApiResponsePayload` to the **real**
`ApiToUiValidator` and `RulesValidator`. Nothing is mocked except the
socket.

Each row asserts: the expected validator id, the expected status, and
that the failure carries raw / transformed / actual. The test writes
`docs/evidence/api_to_ui_matrix.md` so the acceptance report quotes
measured output rather than prose.

- [ ] Correctness rows (must PASS): normal, empty string, null field,
      missing field, zero, very large.
- [ ] Defect rows (must FAIL, on the named validator):
      price 2999 → "₹2599"; `available:false` with Add to Cart enabled;
      "Nike Air Max" → "Nike Air"; `image:null` with the image widget
      still rendered; discount badge shown at `discount == 0`; cart total
      ignoring the delivery fee; wrong currency symbol.
- [ ] Assert **no** `ValidationResult` anywhere carries a confidence
      field - the rule that makes the rest trustworthy.
- [ ] Commit.

---

### T7 - API error matrix

`examples/ecommerce_app/test/platform/api_error_matrix_test.dart` plus
`packages/flutter_testsmith_cli/test/mock_api_server_test.dart`.

- [ ] The server really returns 400 / 401 / 403 / 404 / 500, really
      delays past the client timeout, and really returns a body that is
      not JSON.
- [ ] The app renders a defined error state for each, and the UI tree
      exposes it - so a flow can assert on it.
- [ ] `validateScreen` reports **error**, not **fail**, when there is no
      response to compare against: "the API never answered" is not "the
      price is wrong".
- [ ] Commit.

---

### T8 - Figma defect matrix

- [ ] Author `examples/ecommerce_app/figma/checkout.json` in the exact
      normalised shape, and its `.mapping.yaml`. Label it in the file as
      hand-authored, because no Figma token is configured here and
      pretending otherwise would be a lie in a document about honesty.
- [ ] `packages/flutter_testsmith_engine/test/figma_defect_matrix_test.dart`: one
      seeded defect at a time - missing element, wrong element type,
      incorrect text, wrong position, wrong dimensions, wrong typography,
      wrong colour, incorrect spacing - each asserting the exact
      validator id (`figma-structure`, `figma-type`, `figma-text`,
      `figma-geometry`, `figma-typography`, `figma-colour`,
      `figma-order`) and status.
- [ ] Assert the two honest-skip behaviours survive: text ignored by
      default, vertical geometry skipped on an aspect mismatch.
- [ ] Writes `docs/evidence/figma_defect_matrix.md`.
- [ ] Commit.

---

### T9 - Screenshot capture architecture

**Investigate first, implement second, and publish the limits either
way.**

- [ ] Answer, in `docs/adr/0010-screenshot-capture.md`: what each path
      captures, what it excludes, which coordinate system it produces,
      how `devicePixelRatio` is handled, whether it is suitable for
      design comparison, and whether it is deterministic across runs.
- [ ] Implement `ext.mytest.screenshot` over
      `OffsetLayer.toImage(paintBounds, pixelRatio:)` if - and only if -
      it proves stable on the real device. Return base64 PNG plus width,
      height, ratio and `source: repaintBoundary`.
- [ ] Measure determinism: N identical captures, byte equality and pixel
      difference.
- [ ] If unstable, **document the exact limitation and stop**. The
      existing `screencap` path already works; a second flaky one is a
      liability.
- [ ] The store's refusal to diff across capture paths must keep
      holding - it is what makes two paths safe to have at all.
- [ ] Commit.

---

### T10 - Impact analysis stress

- [ ] `packages/flutter_testsmith_engine/test/impact_stress_test.dart` over an index
      built from the real seven-screen app.
- [ ] Changing `product_details_screen.dart` selects the ProductDetails
      flow. Whether it also selects Cart and Checkout is a **finding**,
      not an assumption: the brief asks whether the system does, and the
      current attribution is by declared screen and semantic id, which
      does not follow navigation. Measure it, then decide.
- [ ] A change touching two screens selects both and nothing else.
- [ ] An unattributable file, a router change, a pubspec change and an
      asset change each select everything, each with the reason that
      actually applies.
- [ ] A docs-only change selects nothing.
- [ ] Run `testsmith impact --changed <path>` for each case and capture the
      output into `docs/evidence/impact_matrix.md`.
- [ ] Commit.

---

### T11 - AI boundaries

`packages/flutter_testsmith_engine/test/ai_boundaries_test.dart`, driven by a fake
`LlmClient` that is deliberately hostile.

CAN - assert the capability exists:
- [ ] explain failures; suggest mappings (under `suggested:`); suggest
      scenarios; identify likely causes; attach confidence to a
      hypothesis.

CANNOT - assert the capability is structurally impossible:
- [ ] A model replying "everything passed" leaves a failed run failed.
- [ ] Analysis never writes to a mappings file; `suggested:` entries are
      never promoted into `mappings:`.
- [ ] Every generated flow is `status: proposed` **even when the model
      writes `status: approved`**, and the runner refuses it.
- [ ] Generation never edits an existing flow file; a proposal reusing an
      existing flow name is rejected rather than overwriting.
- [ ] A model cannot turn `skip` or `error` into `pass`: assert
      `ValidationReport.passed` is false when the only non-pass is an
      `error`, and that `RunResult.passed` ignores `analysis` entirely.
- [ ] Commit.

---

### T12 - Generated scenario validation

- [ ] Extend `GenerationEvidence` with `fixturesThatExist`, and reject a
      proposal that names an unknown fixture or declares no precondition.
- [ ] Regenerate `tests/proposed/` against the real fixture names, or -
      if no model key is configured in this environment - hand-author the
      equivalent set and say plainly in the acceptance report which it
      was.
- [ ] `packages/flutter_testsmith_engine/test/generated_scenario_validity_test.dart`:
      every committed proposal parses, names an existing screen, names
      only existing ids, names an existing fixture, is `status: proposed`,
      and is refused by the runner.
- [ ] Commit.

---

### T13 - Device validation and visual measurement

Physical: **SM-M127G**, serial `RZ8T11QETWM`, Android 13. Emulator:
`mytest_api33`.

- [ ] `testsmith doctor`, `devices`, `smoke --tap-id home.open_product`.
- [ ] The full flow: login → home → products → details → cart → checkout
      → success, with `--mock-api`.
- [ ] Verify on-device: launch, attach, handshake, navigation, UI
      inspection, API capture, screenshot, tap-by-id, validation.
- [ ] **Visual repeatability:** five runs of the unchanged ProductDetails
      screen. Record differing ratio, SSIM, max channel delta and wall
      time for each. Count false positives.
- [ ] **Seeded defect repeatability:** three runs with
      `--dart-define=SEED_PRICE_BUG=true`. Record whether detection is
      unanimous.
- [ ] Run the same core flow on the AVD and document every difference.
- [ ] Everything into `docs/evidence/device-runs.md`.

---

### T14 - Security validation

- [ ] Seed a distinct, greppable secret for each of: authorization token,
      password, access token, refresh token, OTP, card number, CVV.
- [ ] `packages/flutter_testsmith/test/secret_leakage_test.dart`: each seeded
      secret goes through `NetworkCapture` and appears in **no** emitted
      event - asserted by searching the serialised JSON of every event
      for the literal, not by checking the keys that were redacted.
- [ ] `packages/flutter_testsmith_engine/test/report_leakage_test.dart`: the same
      literals appear in neither `result.json` nor the rendered HTML nor
      the JSON handed to the AI client.
- [ ] Prove redaction happens **at capture**: assert the payload object
      itself already holds `[REDACTED]` before any reporting code runs.
- [ ] On the device, grep the real `out/result.json` and `out/report.html`
      for every literal after a real run.
- [ ] Commit.

---

### T15 - Reports

- [ ] `docs/PHASE_12_ACCEPTANCE.md` - every capability as PASS / FAIL /
      PARTIAL / NOT IMPLEMENTED, each with a named piece of evidence.
- [ ] Update this file with what was actually found.
- [ ] Discovered defects, fixed defects, remaining limitations, test
      counts, device results, visual measurements, the API→UI matrix, and
      a recommendation for Phase 13.

---

## Self-review

**Spec coverage** - every numbered requirement in §0 maps to a task.
Items 13 (do not implement) and 14 (final output) map to the global
constraints and T15 respectively.

**Type consistency** - `ApiScenario`/`ScenarioRoute` are introduced in T3
and consumed by name in T7, T12 and T13. `Defects` is introduced in T5 and
consumed in T6 and T13. `Evidence(kind: 'apiValue')` is introduced in T5
and asserted in T6.

**Known risk to the plan** - T10 may find that impact analysis does *not*
select Cart and Checkout for a ProductDetails change, because attribution
is by declared screen and semantic id and does not follow navigation
edges. That is a finding to report under the "is it safe?" rule, not a
licence to rewrite the analyser mid-phase.

---

# What actually happened

The plan above was followed. This section records where reality differed
from it, because a hardening phase that quietly rewrites its own plan has
disproved its own point.

**Outcome:** [docs/PHASE_12_ACCEPTANCE.md](docs/PHASE_12_ACCEPTANCE.md).
**Evidence:** [docs/evidence/](docs/evidence/).

## Additions the plan did not anticipate

Four, each because something could not be expressed otherwise. All are
additive; none changes the architecture, and the STOP rule was therefore
not triggered.

| Addition | Why it became necessary |
|---|---|
| **`expectElement` step** (T3-adjacent) | With an error fixture in play every mapped element is legitimately absent, so `validateScreen` reports error - correctly, and there was no way to say "and that is what should happen". Without it, no error-state flow could exist on a device. |
| **`textAnchor` per screen** (T13) | A right-aligned total whose right edge was 0.9px from the design reported x as 50.8px out. See below - this was first attempted as an inference and that was wrong. |
| **Bottom-anchored ignore regions** (T13) | The navigation bar cost a constant 0.065% of every comparison and could not be written down without hard-coding a device height. |
| **Per-fixture visual baselines** (T13) | The out-of-stock screen legitimately differs from the in-stock one; there was no way to hold a baseline for both. |

## A wrong turn, recorded

`textAnchor` was first implemented as an **inference** from Figma's
`textAlign`. It fixed `/checkout` and immediately broke
`/product/details`: the cart total there is left-positioned by the
layout while its design node says `textAlign: CENTER`, and the inference
reported a pixel-perfect element as 5.7px out.

Figma's `textAlign` describes where glyphs sit **inside** the text
node's box, not how that box is anchored in its parent. The two are
unrelated, and the platform cannot tell them apart. So it is declared by
the team that knows, and the test that would have caught the inference
is committed alongside it.

## Where the plan's guesses were right

T10 predicted that impact analysis might not select Cart and Checkout
for a ProductDetails change, because attribution is by declaration
rather than by navigation. It does select them - but only because a
journey flow traverses them, not because the analysis understands the
edge. Reported as limitation L2 rather than fixed, exactly as the plan
said it should be.

## Where the plan was wrong

T6 and T7 assumed one matrix could drive the whole chain - real socket,
real widgets, real validators - in a widget test. It cannot.
Initialising the Flutter test binding replaces `HttpOverrides.global`
with one answering every request with a canned 400, and a request issued
from `initState` is never delivered at all: a `MockApiServer` bound
inside a widget test never sees the connection, and the test hangs until
it times out. Measured, after two runs that had to be killed.

The chain is therefore proven in three pieces rather than one: transport
over a real socket in a binding-free file, UI states in widget tests, and
the join on a device. That is weaker than one end-to-end matrix and it is
what is true.

## Tasks as delivered

| Task | Delivered | Note |
|---|---|---|
| T1 baseline | yes | found 3 failing tests and 7 unrunnable proposals |
| T2 fix the broken tests and proposals | yes | D-01 fixed; D-02 fixed in T12 once fixtures existed |
| T3 fixture scenarios | yes | 22 scenarios, `fixture:` in the flow language |
| T4 the application | yes | 7 screens, 4 states each, null-tolerant parsing |
| T5 structured evidence and the defect seam | yes | `Defects`, and the raw API value is now machine-readable |
| T6 API→UI defect matrix | yes | 18 rows, 7 seeded defects, all caught |
| T7 API error matrix | yes | split in two - see above |
| T8 Figma defect matrix | yes | all 8 defect classes, plus 4 honest-skip rows |
| T9 screenshot architecture | yes | implemented and measured; ADR-0010 |
| T10 impact stress | yes | found D-07, the worst defect of the phase |
| T11 AI boundaries | yes | 28 tests against a hostile model |
| T12 generated scenario validation | yes | 9 proposals, each naming a real fixture |
| T13 device validation | yes | 13 runs on hardware, 1 on the AVD |
| T14 security | yes | 7 secrets, unit-tested and grepped in real artefacts |
| T15 reports | yes | this file and the acceptance report |

## Not implemented, as instructed

Cloud backend, dashboard, autonomous exploratory AI, device farm,
multi-user system, release-mode WebSocket transport. None was started.
