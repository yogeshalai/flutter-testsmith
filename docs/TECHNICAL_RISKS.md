# Technical Risks

**Date:** 2026-09-10

Risks are ordered by expected cost (likelihood x impact), not by phase.
"Retired by" names the phase whose exit criteria prove the mitigation works.

---

## R1 - VM Service attach is unreliable or racy

**Likelihood:** medium **Impact:** critical - blocks everything

The entire platform depends on the runner attaching to the app's VM Service
and exchanging events. Failure modes: the ws URI is not emitted or changes
format in a future Flutter release; DDS occupies the port; hot restart
invalidates the connection; the app terminates during attach.

**Mitigations**

- `flutter run --machine` gives structured JSON rather than scraped log text.
- Bounded retry with explicit, differentiated diagnostics per failure mode -
  never a generic "could not connect".
- `SdkTransport` is an interface, so `WebSocketTransport` is a fallback that
  does not require redesign.
- Attach is exercised on every `testsmith smoke` run, so regressions surface
  immediately.

**Retired by:** Phase 1.

---

## R2 - Events lost before the runner subscribes

**Likelihood:** high (certain without mitigation) **Impact:** high

`postEvent` is fire-and-forget. Session start and the first `ScreenEnter` are
emitted before the runner can subscribe, and those are the most important
events in the run.

**Measured 2026-09-10.** With DDS disabled, 0 of 50 pre-subscription events
were delivered - the risk is real. With DDS (which `flutter run` starts by
default), all 50 were replayed in order, but the replay is capped at exactly
10,000 events per stream and drops oldest-first.

**Mitigation:** bounded SDK-side ring buffer drained by the `handshake` RPC
(ARCHITECTURE 8.1). Bounded so an unattached app cannot grow without limit.
DDS replay is *not* relied upon: it is an undocumented host-tool detail,
absent under `--no-dds` and on direct VM Service connections.

**Retired by:** Phase 1 exit criteria explicitly assert recovery of
pre-subscription events.

---

## R2b - Duplicate event delivery

**Likelihood:** certain **Impact:** high - duplicated screen transitions

Discovered by measurement, not anticipated in the original design. DDS replay
and the handshake drain deliver the same startup events, so every event
emitted before attach arrives twice.

**Mitigation:** the engine deduplicates by `eventId`, keeping the first
occurrence and preserving arrival order. Neither sequence may be assumed
complete on its own - DDS replay is capped, the ring buffer is bounded - so
the deduplicated union of both is the authoritative history.

**Retired by:** Phase 1, with a test asserting that a duplicated event stream
yields exactly one logical event per `eventId`.

---

## R3 - Logical vs physical pixel confusion

**Likelihood:** high **Impact:** high - wrong taps, false geometry failures

UI tree bounds are Flutter logical pixels; `adb shell input` and screenshots
are physical pixels.

**Mitigations**

- SDK reports `devicePixelRatio` in the handshake; exactly one conversion
  function exists; ad-hoc multiplication is prohibited.
- **Validated by the choice of test device:** the Samsung SM-M127G runs at
  300dpi, giving DPR 1.875. A non-integer ratio makes any conversion error
  immediately and visibly wrong, where a 2.0 device would mask whole classes
  of mistake.

**Measured 2026-09-10 on the device.** The mitigation held, but the
measurement exposed a second, sharper problem, recorded as R3b.

**Retired by:** Phase 2.

---

## R3b - The device pixel ratio at attach is not yet the real one

**Likelihood:** certain on Android **Impact:** high - every tap mis-placed

Discovered by running against the device rather than by reasoning. The
handshake happens as soon as `flutter run` reports `app.started`, which on
Android is **before the first frame**. At that moment the view reports a
default `devicePixelRatio` of 1.0. The real value on the test device is
1.875, so a coordinate converted with the attach-time value lands at 53% of
its intended position.

What makes this genuinely dangerous is that **1.0 is a legitimate ratio**.
The SDK cannot distinguish "not yet laid out" from "really is 1.0", so
there is no flag it can set and no value it can withhold. Verified directly:
the application renders `sdk dpr 1.875  mediaQuery 1.875` on screen while
the handshake taken moments earlier reported 1.0.

**Mitigation:** the ratio is resolved per use rather than captured once, and
**the engine must read it at the time it converts a coordinate, never from
the attach-time handshake**. `ext.mytest.sessionInfo` returns a freshly
resolved `AppContext` for exactly this. `testsmith smoke` reports both values
side by side so the discrepancy stays visible.

For Phase 2 this is binding: tap-by-id must read bounds and ratio together,
at tap time, from the same settled read.

**Retired by:** Phase 2, where the conversion has a real consumer.

---

## R4 - UI tree too large or too lossy

**Likelihood:** medium **Impact:** high

A raw element tree is thousands of nodes per screen - too large to ship on
every transition. Filter too aggressively and the tree stops being a faithful
functional record.

**Mitigations**

- Hybrid walk with explicit retention rules (ARCHITECTURE 9.5).
- A stated node-count and payload-size budget, asserted in tests.
- Retention rules are configurable, so a team can widen them for a screen that
  needs it.

**Measured 2026-09-10 on the device.** The first implementation retained
32 nodes from 261 elements (87.7% filtered), but ten of those were empty
`Semantics` wrappers with identical bounds and every `Text` carried a
duplicate `RichText`. Root cause: retention keyed off
`RenderObject.debugSemantics`, which reports the semantics node an element
*contributed to* - often an ancestor's - so everything inside a labelled
subtree looked interesting.

Retention now requires an element to carry semantic data *itself*, and a
lone child that restates its parent's text and bounds is collapsed. The
same screen now yields 9 nodes from 261 elements (96.6% filtered), and a
node-count budget is asserted in tests so the filter cannot quietly
regress.

**Retired by:** Phase 2.

---

## R4b - A tree captured mid-transition contains two screens

**Likelihood:** high **Impact:** medium - misleading trees, false failures

Observed directly: capturing two seconds after a tap returned a tree
holding *both* screens - the outgoing one at negative x coordinates as it
slid away, and the incoming one - for 25 nodes instead of the 9 the
settled screen produces.

Nothing is wrong with the capture; the screen genuinely was in that state.
But a validation run against such a tree would compare against a
composite that matches no design and no expectation.

**Mitigation:** settle detection (ARCHITECTURE 10.3) - no new frames for a
quiet period, no in-flight requests, no running animations - before any
capture used for validation. Until that lands in Phase 4, `inspect` and
`smoke` simply wait a fixed interval, which is honest but not sufficient,
and the negative x coordinates are the tell that it was not enough.

**Retired by:** Phase 4.

---

## R5 - Screenshot fidelity and comparability

**Likelihood:** medium **Impact:** high (Phase 7)

Two capture paths exist and they do not produce identical images: in-app
`RepaintBoundary.toImage()` (Flutter surface only, no system UI, exact logical
geometry) and `adb exec-out screencap` (true device output, includes status
bar, subject to OS scaling).

Mixing them across runs would produce meaningless diffs.

**Mitigations**

- Capture path is recorded in the `Screenshot` event; comparison refuses to
  diff images captured by different paths.
- `RepaintBoundary` is the default for design comparison; `screencap` is used
  for whole-device evidence.

**Retired by Phase 12, with one mitigation corrected.** Both paths now
exist and were measured on the SM-M127G: `screencap` gives 720x1600,
the surface path 720x1510, both byte-deterministic across runs. The
store refuses to compare across paths, and a real run was made to
produce that refusal.

The second mitigation above was **wrong** and has been reversed.
`screencap` is the default, because every committed baseline used it and
because it is the only path that sees a system dialog sitting on top of
the application. Neither path is suitable for design comparison - see
[ADR-0010](adr/0010-screenshot-capture.md) and R7.

---

## R6 - Visual diff false positives

**Likelihood:** high **Impact:** medium - erodes trust, which is fatal

Antialiasing, font hinting, animation mid-flight and GPU differences make
naive pixel comparison noisy. A visual check that cries wolf gets disabled.

**Mitigations**

- Settle detection before capture (no mid-animation frames).
- Perceptual (SSIM) comparison alongside raw pixel counts, with tolerances per
  check rather than one global constant.
- Ignore regions for dynamic content.
- False-positive rate measured across repeated identical runs as an explicit
  exit criterion, not assumed.

**Retired by Phase 12.** Five runs of an unchanged screen on real
hardware: 0.000% differing, ssim 1.0000, **zero false positives**, with
the measurement identical to three decimal places every time. Three runs
of a seeded defect: detected 3 of 3, at 17.901% each time.

Getting there required finding one more source of constant noise that
Phase 7 missed: the navigation bar, which differed by 723 pixels on
every run - a third of the whole-screen tolerance budget. Ignore regions
can now be anchored to the bottom of the image so a system bar can be
written down without hard-coding a device height.

---

## R7 - Figma render is not Flutter render

**Likelihood:** high **Impact:** medium

Figma and Flutter disagree on font rendering, text metrics, and pixel density.
Pixel-exact equality between a Figma export and a device screenshot is not
achievable and should not be promised.

**Mitigation:** Figma is the authority for **structure, geometry, typography
and colour** (Phase 6, deterministic and tolerance-based). Figma-to-screenshot
pixel comparison is treated as advisory, and the documentation says so rather
than implying an accuracy the technique cannot deliver.

**Confirmed against a real file (Phase 5).** The design pulled for
development is a food-delivery product page whose layers are named
`Frame 42980` and `Rectangle 91`. Nothing in it could be matched to an
application element by name, which is why the mapping layer exists and
why it maps by node id.

**Retired by:** Phase 6 (structural). Phase 7 documents the visual limit.

---

## R7b - A design and an application can describe different products

**Likelihood:** high **Impact:** high - comparison becomes noise

The Figma frame supplied for development describes "Example Restaurant", a
food-delivery product page (`Nonveg-Burger`, `Rs 90/Unit`). The example
application in this repository is a shoe shop (`Nike Air Max`).

Structural comparison between them would report every element as missing
and every value as wrong - technically a working comparison, and
completely useless. This is not a defect in the comparison; it is what
happens when a design and a screen are not of the same thing.

**Mitigation:** a design spec declares the `screen` it describes, and
comparison only runs for a screen that has one. Before Phase 6 can
demonstrate anything meaningful, the design and the application under
test must be of the same product - either by pointing the platform at
the application this design belongs to, or by building the example to
match the design.

**Retired by:** Phase 6, once design and application correspond.

---

## R8 - API-to-screen attribution ambiguity

**Likelihood:** medium **Impact:** high - flaky, unreproducible results

Requests fired during navigation transitions, prefetches, and background
polling can plausibly belong to two screens.

**Mitigations**

- One deterministic rule, documented: attribute by **request issue time**,
  plus a configurable grace window (default 2s) after `SCREEN_ENTER`.
- Never attribute by response time.
- Unattributable exchanges are reported as such rather than silently dropped
  or arbitrarily assigned.

**Retired by:** Phase 3.

---

## R9 - Network interception coverage is narrower than claimed

**Likelihood:** medium **Impact:** medium

`HttpOverrides` covers `dart:io`-based clients but not custom adapters,
`package:web` / `fetch` on web, native-side HTTP in plugins, gRPC, or
WebSockets.

**Mitigation:** publish a tested support matrix and state the unsupported
cases explicitly. Never claim universal interception (specification section G
requires exactly this restraint).

**Supported, as of Phase 3** - verified against a real socket, not a mock:

| Client | Captured | How |
|---|---|---|
| `dart:io` `HttpClient` | yes | `CapturingHttpOverrides`, zero config |
| `package:http` `IOClient` | yes | goes through `HttpClient` |
| dio, default adapter | yes | goes through `HttpClient` |
| dio, custom adapter | no | app calls `TestSdk.network` directly |
| `package:web` / fetch (web) | no | no `dart:io` |
| Native-side HTTP in a plugin | no | never enters the Dart VM |
| gRPC, WebSockets | no | not HTTP request/response |

`flutter_testsmith` deliberately takes **no dependency on dio or `package:http`**.
It is linked into production applications, so every dependency added here
becomes one for every application under test. The unsupported clients are
served by the public `NetworkCapture` API instead, which is the same code
path the built-in adapter uses - so there is only ever one place a
credential could leak.

**Retired by:** Phase 3.

---

## R10 - Secret leakage into events or reports

**Likelihood:** medium **Impact:** critical - a security incident

Tokens and PII flowing into stored artifacts or CI logs.

**Mitigations**

- Redaction at capture time, in-process - a secret that never enters an event
  cannot leak downstream.
- Allow-by-exception defaults for known-sensitive keys.
- An automated test asserts a seeded token appears nowhere in emitted events,
  `result.json`, or the HTML report.

**Retired by:** Phase 3 (partially Phase 1, since the policy type ships then).

---

## R11 - Instrumentation reaches production

**Likelihood:** low **Impact:** critical

**Mitigations:** three independent layers (ARCHITECTURE 9.2) - compile-time
constant enabling tree-shaking, runtime `kReleaseMode` guard, and the absence
of the VM Service in release builds. A test asserts that a release-mode
`initialize()` without opt-in registers no extension.

**Retired by:** Phase 1.

---

## R12 - Protocol drift between SDK and engine

**Likelihood:** low (by construction) **Impact:** high

**Mitigation:** both sides consume the same `flutter_testsmith_protocol` package - the
primary reason for the all-Dart decision. Reinforced by shared JSON fixtures
asserted from both the SDK and engine test suites, so a change that breaks one
side fails the other's tests.

**Retired by:** Phase 1.

---

## R13 - Release-mode testing is impossible over VM Service

**Likelihood:** certain **Impact:** medium, deferred

VM Service requires debug or profile builds, so release-build behaviour
(obfuscation, tree-shaking, release-only code paths) cannot be tested by the
Phase 1 transport.

**Mitigations:** profile mode is much closer to release than debug and is
supported. `WebSocketTransport` is the planned path to true release testing.
This limitation is documented rather than hidden.

**Retired by:** deferred, deliberately.

---

## R14 - Single physical device is a bottleneck

**Likelihood:** high **Impact:** medium

One Samsung SM-M127G, USB-attached to a developer machine. It sleeps, locks,
disconnects, and is unavailable when the developer leaves.

**Mitigations**

- `wake()` and stay-awake handling in `AdbDeviceController`; a locked device
  produces a clear diagnostic rather than a tap timeout.
- AVD `mytest_api33` is verified working as a fallback and as the CI target.
- `DeviceController` is an interface, so a device farm is an implementation.

**This happened during Phase 3.** The phone dropped off USB mid-run. The
failure was legible rather than mysterious - `adb -s RZ8T11QETWM shell input
keyevent KEYCODE_WAKEUP exited with 1: device not found` - which is what the
diagnostic mitigation was for, and the AVD fallback completed the phase.
Usefully, the emulator runs at density 420 (ratio 2.625) against the phone's
1.875, so the same tap-by-id test passed unchanged on two different ratios.

**Retired by:** Phase 1 for diagnostics; ongoing otherwise.

---

## R15 - Pure-Dart image processing is too slow

**Likelihood:** medium **Impact:** medium (Phase 7 only)

The `image` package is pure Dart and slower than `sharp` or OpenCV. A 720x1600
screenshot at DPR 1.875 is a moderate workload; full-suite visual diffing
could become the slowest stage.

**Mitigations:** run comparisons in isolates; downscale before perceptual
comparison; compare only changed regions where possible. If it still proves
too slow, an out-of-process native comparator behind the existing comparison
interface is the escape hatch - an implementation change, not a redesign.

**Retired by:** Phase 7, with a measured benchmark.

---

## R16 - Declarative navigation is hard to observe

**Likelihood:** medium **Impact:** medium

`NavigatorObserver` covers imperative navigation well. `go_router` and other
declarative routers report transitions differently, and shells, tabs and
nested navigators can produce ambiguous or duplicated screen events.

**Mitigation:** router-specific adapters behind one interface; explicit
`TestScreen` annotation as the highest-priority and always-available override,
so no team is blocked by their router choice.

**Retired by:** Phase 2 for the example app; per-router as encountered.

---

## R17 - AI nondeterminism, cost and overreach

**Likelihood:** high **Impact:** medium

LLM output varies between runs, costs money per invocation, and invites
scope creep into decisions it must not own.

**Mitigations**

- Structural separation (ARCHITECTURE 2): AI never produces a verdict, so its
  variance cannot change whether a test passes.
- AI runs only on failures, and only when explicitly enabled.
- Responses are cached against the deterministic result hash, so a re-run of
  an unchanged failure costs nothing.
- Every AI output is labelled confirmed / probable cause / hypothesis.

**Retired by:** Phase 8.

---

## R18 - iOS cannot be developed or verified on this host

**Likelihood:** certain **Impact:** medium, deferred

**Mitigation:** `DeviceController` and `SdkTransport` are platform-neutral
interfaces and the VM Service transport is already platform-agnostic, so iOS
is an implementation task on a macOS host rather than an architectural change.
No iOS support is claimed until it is run.

**Retired by:** deferred.

---

## Risks explicitly accepted without mitigation

| Risk | Why accepted |
|---|---|
| Hand-written JSON serialization drifts from models | Small model count in Phase 1; round-trip tests catch it; revisit with `build_runner` only if the count grows |
| No cloud backend, so no cross-run history | Specification section 22 defers it; `result.json` is the stable contract that makes adding it later straightforward |
| Windows-only development host | Team constraint; CI can add Linux later without design change |
