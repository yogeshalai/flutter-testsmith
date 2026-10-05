# Implementation Plan

**Date:** 2026-09-10
**Approach:** working vertical slices, one phase at a time. The repository is
runnable and green at the end of every phase.

---

## Ground rules

1. **No speculative code.** A phase implements the smallest useful version of
   its capability, with tests, and nothing beyond it.
2. **The repository stays runnable.** `dart analyze` clean and all tests green
   at every phase boundary.
3. **Completion is demonstrated, not asserted.** A phase is done when its exit
   criteria have been *run* and their output shown - never on unit tests alone
   where the phase claims device behaviour.
4. **Architecture changes stop work.** A discovered limitation that requires
   changing the architecture halts implementation and is escalated with
   problem, current design, proposal, alternatives and recommendation.

---

## Phase 1 - Foundation: SDK, protocol, CLI, device attach

**Goal:** prove the riskiest assumption in the entire architecture - that the
runner can reliably launch a Flutter app, attach to it over the VM Service,
exchange typed events with our in-app SDK, and lose nothing at startup.

Everything else in the platform is built on that channel. If it is unreliable,
we need to know in week one, not in Phase 7.

### Tasks

| # | Task | Package |
|---|---|---|
| 1.1 | Pub workspace root, strict `analysis_options.yaml`, `.gitignore` | root |
| 1.2 | `TestEvent` envelope, `EventType`, `AppContext`, sealed `EventPayload` | flutter_testsmith_protocol |
| 1.3 | Six Phase 1 payloads: SessionStart/End, ScreenEnter/Exit, AppLog, Heartbeat | flutter_testsmith_protocol |
| 1.4 | Protocol version constant + `HandshakeRequest`/`HandshakeResponse` | flutter_testsmith_protocol |
| 1.5 | JSON round-trip tests + shared fixture files | flutter_testsmith_protocol |
| 1.6 | `TestSdkConfig` (incl. `RedactionPolicy` type, unused until Phase 3), `TestSdk.initialize()`, three-layer production gating | flutter_testsmith |
| 1.7 | `SdkChannel` interface + `VmServiceChannel` (registerExtension/postEvent) | flutter_testsmith |
| 1.8 | Bounded ring buffer, drained by `handshake` | flutter_testsmith |
| 1.9 | `TestNavigatorObserver` emitting ScreenEnter/ScreenExit | flutter_testsmith |
| 1.10 | `TestKey` / `TestId` (declared in Phase 1, consumed in Phase 2) | flutter_testsmith |
| 1.11 | RPCs: `ext.mytest.handshake`, `.ping`, `.sessionInfo` | flutter_testsmith |
| 1.12 | Widget tests against a fake channel | flutter_testsmith |
| 1.13 | `SdkTransport` interface + `VmServiceTransport` | flutter_testsmith_engine |
| 1.14 | `flutter run --machine` process driver + ws URI discovery | flutter_testsmith_engine |
| 1.15 | `DeviceController` interface + `AdbDeviceController` (info/launch/terminate/screenshot/wake/reversePort) | flutter_testsmith_engine |
| 1.16 | `SessionManager`: session lifecycle, event ordering, screen stack | flutter_testsmith_engine |
| 1.17 | Engine unit tests against a fake transport | flutter_testsmith_engine |
| 1.18 | `testsmith doctor` - toolchain, adb, device, SDK version checks | flutter_testsmith_cli |
| 1.19 | `testsmith devices` | flutter_testsmith_cli |
| 1.20 | `testsmith smoke` - launch, attach, handshake, navigate, print event stream | flutter_testsmith_cli |
| 1.21 | Minimal 2-screen example app wired to the SDK | examples |
| 1.22 | Dependency-direction CI assertion | scripts |

### Exit criteria

- `dart analyze` clean across the workspace; all unit tests green.
- `testsmith doctor` reports the real toolchain state and fails informatively when
  something is missing.
- **On the physical Samsung SM-M127G:** `testsmith smoke` launches the example
  app, attaches over the VM Service, completes the handshake, drives a
  navigation, and prints a correctly ordered event stream **including the
  pre-subscription events recovered from the ring buffer**.
- Protocol version mismatch produces a clear hard failure (tested by forcing a
  mismatch).

### Explicitly out of scope

Widget tree capture, tap-by-ID, network capture, YAML DSL, Figma, visual diff,
AI, HTML report. Each has its own phase.

---

## Phase 2 - Semantic UI tree and screenshots

**Goal:** a filtered, enriched UI tree and a screenshot, on demand, for the
current screen.

- Hybrid element + semantics walk (ARCHITECTURE 9.5); retention and flattening
  rules; `devicePixelRatio` reporting.
- `ext.mytest.uiTree`, `ext.mytest.screenshot` (RepaintBoundary capture).
- `TestKey` / `TestId` resolution into stable IDs.
- Engine-side element lookup by ID, and the single logical->physical
  conversion function.
- `testsmith inspect` (dump the tree), `testsmith screenshot`.
- Tap-by-ID: resolve ID -> bounds -> centre -> `adb shell input tap`.

**Exit:** on the device, `testsmith inspect` returns a tree in which every
`TestKey` in the example app is present with correct bounds, and a tap-by-ID
navigates. Tree size for a typical screen stays within a stated budget.

**Risk retired:** whether the filtered tree is small enough and accurate
enough to be the primary functional validation mechanism.

---

## Phase 3 - Network capture and correlation

- `CaptureAdapter` interface; dio, `package:http`, and `HttpOverrides`
  implementations.
- Redaction at capture time; body truncation.
- `ApiRequest`/`ApiResponse` events, paired into `ApiExchange`.
- API-to-screen attribution rule with the grace window (ARCHITECTURE 10.3).
- Mock API server for the example app; `adb reverse` wiring for the physical
  device.

**Exit:** navigating to a screen produces exchanges correctly attributed to it,
with secrets redacted, verified by a test that asserts a token never appears
anywhere in the emitted events.

---

## Phase 4 - API to UI mapping and deterministic validation

- `mappings.yaml` schema and loader; `suggested:` block parsed but inert.
- Transformation registry (`currency`, `date`, `boolToEnabled`, ...).
- `ApiToUiValidator`, `UiPresenceValidator`.
- Declarative rules engine (specification section 6): conditions and
  expectations.
- YAML test DSL: sealed `Step` hierarchy, strict parsing with line/column
  errors, executor.
- `result.json` and a first HTML report.
- **Settle detection.**

**Exit:** `testsmith run examples/ecommerce_app/tests/product.yaml` detects a
seeded API-vs-UI price mismatch and reports it with the raw, transformed and
UI values. The full ecommerce example app is built out in this phase, since
this is the first phase that can actually validate it.

---

## Phase 5 - Figma integration

- Figma REST client; auth via environment, never committed.
- Normalised `FigmaScreenSpec` (elements, geometry, typography, colour).
- Figma node to semantic ID mapping layer, human-owned.
- Local caching of Figma responses (rate limits).

**Exit:** a real Figma frame is fetched and normalised into a spec file.

---

## Phase 6 - Figma to Flutter structural comparison

- `FigmaStructureValidator`: required and missing elements, types, ordering,
  geometry, typography, colour.
- Configurable per-check tolerances, no hard-coded constants.

**Exit:** a deliberately removed `product.add_to_cart` is reported as a missing
required Figma element.

**Deviation, recorded when built:** typography and colour needed data the SDK
did not capture - `UiNode.properties` carried semantics flags only. The
inspector was extended to emit the *resolved* text style (size, weight,
family, colour) from the `RenderParagraph`, using the open `properties` bag
the protocol documents as the extension point for exactly this. Reading the
render object rather than the widget is the point: `Text('x')` declares no
style at all, and a design comparison needs what was painted, not what was
written. Design projection is [ADR-0007](adr/0007-design-projection.md).

---

## Phase 7 - Visual comparison

- Deterministic first: pixel diff, then perceptual (SSIM), region and
  element-level comparison.
- Ignore regions for dynamic content.
- Isolate-based execution to keep the runner responsive.

**Exit:** a seeded visual regression is detected with a stable metric and an
acceptably low false-positive rate across repeated runs.

**Measured, not assumed.** Three identical runs on an SM-M127G: 0.000%
differing, ssim 1.0000, zero false positives. Seeded price regression
caught as `product.price differs by 15.552% of its own area`. Two
false-positive sources were found by that measurement and fixed rather
than tolerated: elements below the fold were failing as "outside the
image" on every run, and the status bar clock was spending a fifth of
the tolerance budget. Thresholds and reasoning in
[ADR-0008](adr/0008-visual-comparison.md).

**Not built:** the `RepaintBoundary` capture path R5 anticipates. The
capture path is recorded in each baseline, so adding it later refuses
to compare against screencap baselines rather than silently diffing two
different pictures.

---

## Phase 8 - AI analysis

- `ai_client` (Claude); failure analysis over the deterministic result set.
- Strict output contract: confirmed failure vs probable cause vs hypothesis.
- AI reads results; it never produces or alters verdicts.

**Deviation, recorded when built:** the provider is **Groq**, not Claude, and
is a configuration value rather than a dependency. One
`OpenAiCompatibleClient` serves Groq, OpenAI, OpenRouter, Together, Ollama
and anything else speaking that shape; Anthropic and Gemini are declared as
a separate dialect and refused with an explanation rather than sent a body
they cannot parse. Switching provider is two lines of `ai.yaml`.

The "never alters verdicts" rule is structural: `RunResult.passed` is a
function of the steps and deterministic reports, the analyst takes a
finished result and returns a copy, and a test asserts that a model
insisting everything is fine leaves the run failed. `ValidationResult`
still has no confidence field, also asserted.

Prompt tuned against real output - it first labelled an unproven cause
`confirmed_failure`, then over-corrected into explaining nothing. Both
rules that fix those are in the prompt and covered by tests. See
[ADR-0009](adr/0009-ai-analysis.md).

**Exit:** the Phase 4 price mismatch yields an explanation naming the likely
transformation bug, labelled as a hypothesis with its confidence.

---

## Phase 9 - Automatic screen validation

- `validateScreen` composing every validator over one `ScreenSession`.

**Exit:** a single DSL step reproduces what previously took explicit
assertions.

**Built as a tri-state.** Each flag is `true`, `false`, or absent - and
absent means "decide automatically", not "off". Before this, every flag
defaulted to false, so a bare `validateScreen` validated nothing and
described itself as `validate the screen (nothing)`.

Automatic enables everything that only *reads*. That is safe precisely
because a validator with no configuration skips with a reason rather
than failing, so the report shows every check either as a result or as
a stated reason it could not run - more useful than a row being absent.

The exception is the screenshot comparison, the only check that
*writes*: with no baseline it records one. Automatic therefore requires
a baseline to already exist, because putting a screenshot into the
repository should be a decision someone made rather than a side effect
of running the suite. `visual: true` records one explicitly.

**Flakiness fixed in the same pass.** Three consecutive device runs
failed on a cold start: the element is in the tree before it has been
laid out, so its bounds are zero for a moment and a single capture
turned a slow launch into a test failure. `ElementWaiter` now polls
until the element is tappable, and rethrows the *last real reason*
rather than a generic timeout. Only the two expected conditions are
polled through - absent, or present with no area; a dead transport is
raised at once instead of being retried for ten seconds.

---

## Phase 10 - Git change impact analysis

- Map changed files to screens and flows; select affected tests.
- Full-suite fallback until selection is demonstrably stable.

**Exit:** a change confined to `product_details_screen.dart` selects only
the product flow; a change to the router, to an unrecognised file, or to
the test platform itself selects everything, each with the reason that
actually applies.

**Deterministic, and that is a constraint rather than an omission.** This
decides what gets *tested*: a wrong answer does not produce a visible
failure, it produces a regression nobody looked for. A model may later be
asked to **widen** a selection - to propose a flow this missed - but must
never narrow one, because the cost of the two mistakes is nowhere near
symmetric.

The rule that follows: **a flow is excluded only on positive evidence
that every changed file is unrelated to it.** One file the index cannot
account for selects everything.

Attribution comes from what files declare - a `route` constant, a
`TestKey`, the `screen:` a mappings or design file names - and from what
a flow asserts it reaches. Four path classes are judged by location
rather than content: documentation cannot change behaviour; manifests,
assets and platform folders can reach anything; `packages/` and
`integrations/` are the tool itself, so no previous result about the
application still holds; and a flow file selects its own flow.

---

## Phase 11 - AI test generation and exploratory testing

- Edge-case scenario suggestion from API schemas.
- Suggested tests require explicit approval before execution.

**Exit:** `testsmith generate` proposes scenarios from a real response, the
screen's mappings and the flows that already exist; `testsmith run` refuses
every one of them until a person accepts it.

**The approval gate is structural.** Each generated flow is stamped
`status: proposed` by the generator - not by the model, and any status
the model wrote is replaced, because asking politely is not a control.
The mark lives on the flow rather than on the folder, so pointing the
runner straight at the file still refuses. Accepting means reading the
file and deleting that line. This is the shape already used for AI
mapping suggestions, which land under `suggested:` and stay inert until
promoted by hand.

**Two validations, because syntax is not sense.** A proposal is parsed,
so a generated file can never break the suite. It is then checked
against ids that actually exist - the first real batch expected screen
`product_details` where the id is `/product/details`, which parses
perfectly and fails only once someone runs it on a device.

That check was initially too strict and rejected every correct
proposal: a scenario legitimately taps `home.open_product` on its way
to the product screen, so validation needs every id in the application
and not just the target screen's. The brief keeps the narrow list, so
the model still knows what the screen contains.

**Not built:** exploratory navigation, where a model drives the app
looking for trouble. The plan scopes this phase to suggestion and
approval, and an agent that taps its way around a live build is a
different piece of work with a different risk profile.

---

## Sequencing rationale

Phases 1-3 build the **observation** capability, 4 builds **judgement**, 5-7
add **design and visual** dimensions, 8-11 add **intelligence**. Each layer
depends only on those below it. AI arrives at Phase 8 deliberately: it is only
useful once there is a rich deterministic result set for it to reason about,
and building it earlier would invite it into decisions it must not own.
