# Architecture

**Status:** Living. Sections 1-16 were accepted for Phase 1 on 2026-09-10
and have been kept current since; section 17 was added for the
portability work that followed Phase 12.

For what is built, what is open and which documents are point-in-time
reports, see [PROJECT_STATE.md](PROJECT_STATE.md).

---

## 1. What this is

An AI-native testing platform for Flutter applications. Where a conventional
end-to-end tool validates `user action -> expected result`, this platform
validates the whole chain:

```
user action -> navigation -> API request -> API response -> app state
   -> widget tree -> UI field values -> Figma spec -> screenshot
   -> visual comparison -> AI analysis -> result
```

The target capability is a single DSL step, `validateScreen`, that answers
"is this screen functionally and visually correct?" by correlating the API
response, the live Flutter widget tree, the Figma design, and a set of
declarative business rules.

## 2. The one principle that governs everything

**The deterministic engine decides. AI explains, suggests, and prioritises.**

| Deterministic engine owns | AI owns |
|---|---|
| Exact assertions | Test planning |
| API value comparison | Mapping *suggestions* |
| Widget presence and properties | Ambiguity resolution |
| Geometry tolerance checks | Failure *analysis* |
| Screenshot diff metrics | Explaining differences |
| Navigation and execution | Identifying missing cases |

Two rules follow directly, and both are enforced in code rather than by
convention:

1. **A pass/fail verdict never carries a confidence score.** A deterministic
   comparison either matched or it did not. Attaching a probability to it
   would blur the only line that makes this platform trustworthy. Confidence
   attaches solely to AI-*suggested* artifacts (mappings, hypotheses).
2. **AI never mutates user-authored files.** Suggestions land in a separate,
   clearly-marked block that requires explicit human promotion.

## 3. Environment this was designed against

Captured 2026-09-10 on the development host.

| Component | Version / status |
|---|---|
| Flutter | 3.44.7 stable |
| Dart | 3.12.2 (pub workspaces available) |
| Host OS | Windows 11 Pro 26200 |
| Android SDK | `D:\Android\Sdk`, adb 33.0.3, API 27-37 platforms |
| Test device | Samsung SM-M127G, Android 13 (API 33), arm64-v8a, 720x1600 @ 300dpi (DPR 1.875) |
| Fallback device | AVD `mytest_api33` (android-33 google_apis x86_64), boot verified |
| Node / Python | 20.18.0 / 3.13.3 (available, not required) |
| iOS | **Not possible** - Windows host, no macOS |

Two consequences are load-bearing:

- **iOS cannot be built or tested here.** The architecture must stay
  platform-neutral so iOS support is a later implementation, never a redesign.
  This is why device control sits behind an interface from day one.
- **The test device has a non-integer devicePixelRatio (1.875).** Logical and
  physical pixel confusion is therefore caught immediately rather than masked
  by a convenient 2x ratio. See ADR-0006 and the risk register.

## 4. Technology decisions

### 4.1 Dart for every layer (ADR-0001)

SDK, protocol, engine and CLI are all Dart.

The decisive reason is the protocol. `flutter_testsmith_protocol` is consumed **verbatim**
by both the in-app SDK and the out-of-process runner: one definition of every
event, with no mirrored models to drift apart. In a split-language stack the
event schema must be hand-mirrored or code-generated across a language
boundary, and that boundary is the single most likely long-term source of
silent bugs in a system whose entire job is comparing values.

Supporting reasons: `vm_service` is a first-party Dart package; Flutter
developers already have the toolchain; `dart compile exe` produces a single
`testsmith` binary with no runtime dependency.

Accepted costs: image processing uses the pure-Dart `image` package rather
than `sharp` or OpenCV (adequate for pixel and SSIM comparison; mitigated with
isolates and downscaling - see risks), and HTML reporting is string
templating. Figma and Claude are plain REST/JSON, so no SDK gap exists there.

### 4.2 Dart VM Service as the primary transport (ADR-0002)

A Flutter app in debug or profile mode already exposes the Dart VM Service -
the channel Flutter DevTools itself uses. The SDK registers service extensions
(`ext.mytest.*`) and streams events through `dart:developer`; the runner
discovers the WebSocket URI from `flutter run --machine` and attaches.

Why this over an embedded socket server in the app:

- **One transport, every platform.** Android, iOS, desktop and web behave
  identically. No adb dependency for the data channel.
- **Full fidelity.** Direct access to the element tree, render geometry and
  the semantics tree - everything section E of the specification requires.
- **No listening socket inside the application.** An embedded server needs a
  port, INTERNET permission, and port forwarding, and is a standing production
  safety hazard. The VM Service simply does not exist in release builds.

The accepted limitation is that VM Service requires a debug or profile build,
so release-mode and device-farm execution will eventually need a second
transport. That is an argument for *abstracting* the transport, not for
avoiding VM Service. Hence `SdkTransport` is an interface from Phase 1, with
`WebSocketTransport` as a planned second implementation.

### 4.3 Dart pub workspaces, not melos

Dart 3.6+ supports workspaces natively: one root `pubspec.yaml`, one shared
`.dart_tool`, one `dart pub get`. This removes a third-party dependency and a
class of version-skew problems for no loss of capability.

## 5. System overview

```
                    +-------------------------------+
                    |  testsmith CLI  (flutter_testsmith_cli)       |
                    |  doctor / devices / run       |
                    +---------------+---------------+
                                    |
                    +---------------v---------------+
                    |        flutter_testsmith_engine            |
                    |                               |
                    |  transport/   device/         |
                    |  session/     inspection/     |
                    |  validation/  reporting/      |
                    +----+---------------------+----+
                         |                     |
              SdkTransport                DeviceController
              (VM Service)                (adb)
                         |                     |
   +---------------------v---------+  +--------v------------------+
   |   Flutter app (debug/profile) |  | Android device / emulator |
   |   + flutter_testsmith                  |  | OS input, install, launch |
   |     nav observer              |  +---------------------------+
   |     ui inspector              |
   |     network capture           |        both sides share
   |     ring buffer               |        ... flutter_testsmith_protocol ...
   +-------------------------------+
```

## 6. Package topology

> **Superseded in part by [ADR-0011](adr/0011-single-published-package.md)
> (2026-10-06).** Only `flutter_testsmith` is published. The other
> packages below move inside it as components, and the two invariants
> at the end of this section are now enforced over the import graph as
> well as the dependency graph. The topology below describes the
> repository until that migration completes. The engine has moved
> (`packages/flutter_testsmith/lib/src/engine/`); the CLI, Figma, AI and
> protocol have not.

```
packages/
  flutter_testsmith_protocol/   pure Dart, no runtime deps beyond `meta`. Events, versioning, JSON.
  flutter_testsmith/        Flutter package. In-app instrumentation.
  flutter_testsmith_engine/     pure Dart. Transport, device, session, validation, reporting.
  flutter_testsmith_cli/        Executable. Argument parsing, output formatting only.
integrations/
  flutter_testsmith_figma/  Figma REST client and design normalisation.
  ai_client/       Provider-agnostic chat completions.
```

Both integrations are built. They sit outside `packages/` because both
are **optional** and both talk to external paid services: the platform
builds, tests and runs with neither configured.

Dependency direction is strictly acyclic:

```
flutter_testsmith_protocol  <-  flutter_testsmith                   (Flutter)
flutter_testsmith_protocol  <-  flutter_testsmith_engine  <-  flutter_testsmith_cli  (pure Dart)
```

Two invariants, both checked in review and by a CI dependency assertion:

- **`flutter_testsmith` never depends on `flutter_testsmith_engine`.** The app under test must not
  link the testing brain.
- **`flutter_testsmith_engine` never depends on Flutter.** This keeps the CLI compilable to
  a native binary and lets validation logic unit-test in milliseconds without
  a Flutter harness. It is the single most valuable constraint in the layout.

The specification's `engine/{device,interaction,navigation,runtime,validation,
reporting}` is realised as *directories with barrel exports* inside one
`flutter_testsmith_engine` package rather than six packages (ADR-0003). Dart package
boundaries are heavyweight - pubspec, version, publish and CI wiring each.
Directory boundaries plus explicit barrels give the same modularity and
independent testability; keeping the barrels stable means any module can later
be extracted into a real package without touching an import site.

## 7. Protocol

### 7.1 Envelope

```dart
class TestEvent {
  final String protocolVersion;   // "1.0"
  final String eventId;           // uuid v4
  final DateTime timestamp;       // UTC, microsecond precision
  final String sessionId;
  final String? screenId;
  final EventType type;
  final AppContext app;           // appVersion, buildMode, environment, platform
  final Map<String, Object?> metadata;
  final EventPayload payload;     // sealed
}
```

Payloads are Dart 3 **sealed classes**, so every `switch` over event types is
checked for exhaustiveness at compile time. Adding an event type produces
compile errors at each site that must handle it - the opposite of a silent gap.

Serialization is hand-written `toJson`/`fromJson` in Phase 1. No
`build_runner`: it keeps the edit-test loop fast and the generated-code surface
at zero. This is revisited only if the model count becomes unwieldy.

### 7.2 Versioning

The handshake compares the **major** version. A mismatch is a hard failure with
an actionable message naming both versions and the fix. The protocol never
silently degrades, because a degraded protocol produces wrong test results
rather than an obvious error.

### 7.3 Event catalogue

| Event | Phase |
|---|---|
| `SessionStart`, `SessionEnd`, `Heartbeat` | 1 |
| `ScreenEnter`, `ScreenExit` | 1 |
| `AppLog` | 1 |
| `WidgetTree`, `Screenshot` | 2 |
| `ApiRequest`, `ApiResponse` | 3 |
| `UiInteraction` | 4 |
| `TestAssertion` | 4 |

The envelope is unchanged by any of these additions.

## 8. Transport

```dart
abstract interface class SdkTransport {
  Future<void> connect();
  Stream<TestEvent> get events;
  Future<Object?> invoke(String method, [Map<String, Object?> args]);
  Future<void> close();
}
```

App side, symmetrically:

```dart
abstract interface class SdkChannel {
  void emit(TestEvent event);
  void handle(String method, RpcHandler handler);
}
```

All RPCs are namespaced `ext.mytest.*`. Phase 1 exposes `handshake`, `ping`
and `sessionInfo`.

### 8.1 The startup race, and the ring buffer

`dart:developer`'s `postEvent` is fire-and-forget. Events emitted **before**
the runner subscribes to the `Extension` stream are lost - and those are
precisely the events we care about most: session start, app initialisation,
and the first `ScreenEnter`.

The SDK therefore maintains a bounded ring buffer (default 500 events). The
`handshake` RPC drains it as part of the connect response, so the runner
receives the full history before the first streamed event. Without this,
the first screen of every test run would be subject to a race.

The buffer is bounded so that an app left running without a runner attached
cannot accumulate unbounded memory.

### 8.2 Deduplication by event ID

Measurement (ADR-0002, "Verified capabilities") established that DDS - which
`flutter run` starts by default - independently replays up to 10,000 buffered
stream events to a newly attached client. Startup events therefore arrive
**twice**: once from the DDS replay, once from the handshake drain.

The engine deduplicates by `eventId`, keeping the first occurrence and
preserving arrival order. Deduplication belongs in the engine rather than the
SDK because only the engine sees both delivery paths.

This also means the runner must not assume the replayed and drained sequences
are disjoint, or that either one alone is complete: DDS replay is capped and
may have dropped the oldest events, while the ring buffer is bounded at its
own configured size. The union of the two, deduplicated, is the history.

## 9. Test SDK

### 9.1 Public API

```dart
await TestSdk.initialize(
  config: TestSdkConfig(
    enabled: const bool.fromEnvironment('TEST_MODE'),
    enableNavigationTracking: true,
    enableNetworkCapture: true,
    enableUiInspection: true,
    redaction: RedactionPolicy.strictDefaults(),
    maxBodyBytes: 64 * 1024,
    eventBufferSize: 500,
  ),
);
```

### 9.2 Production safety - three independent layers

Any one layer failing still leaves two:

1. **Compile-time.** `const bool.fromEnvironment('TEST_MODE')` is a
   compile-time constant, so when false the tree-shaker removes the
   instrumentation from the release binary entirely.
2. **Runtime.** `initialize()` refuses to arm under `kReleaseMode` unless an
   explicit `allowInRelease` opt-in is passed, and logs loudly if it does.
3. **Platform.** The VM Service does not exist in release builds, so even a
   mis-gated SDK has no channel out of the process.

### 9.3 Navigation tracking

`TestNavigatorObserver extends NavigatorObserver`, attached through
`MaterialApp(navigatorObservers: [...])`. A `go_router` adapter reads the
router delegate for declarative routing.

Screen ID resolution, in order: an explicit `TestScreen` annotation, then
`RouteSettings.name`, then the widget's `runtimeType`. Unnamed routes degrade
to type names, which are unstable across refactors - the documentation states
this plainly and recommends explicit annotation for any screen under test.

### 9.4 Semantic test IDs (ADR-0004)

Three tiers, so that no team is forced to replace widgets wholesale:

| Mechanism | Use | Cost |
|---|---|---|
| `TestKey('product.name')`, a `ValueKey` subclass | Any widget accepting a key: `Text(x, key: TestKey('product.name'))` | Zero. Marks exactly one widget. |
| `TestId(id: 'product.name', child: ...)` | Subtree scoping; widgets whose key is consumed internally | One extra element in the tree. Survives internal refactors better. |
| `Semantics(identifier:)`, existing keys, semantics labels | Third-party or unowned widgets | None; lower reliability. |

IDs are dotted, stable and meaningful: `home.search`, `product.name`,
`product.add_to_cart`, `checkout.total`.

### 9.5 UI inspection - the hybrid tree (ADR-0005)

Neither of Flutter's two trees alone satisfies the required field set
(`id, type, text, enabled, visible, bounds, children, semantics`):

- The **semantics tree** carries labels and state flags (enabled, checked) but
  loses widget types and omits every node that is not semantically relevant.
- The **element tree** carries real types, keys and geometry (via the attached
  `RenderObject`) but has no concept of "enabled" or of an accessible label.

So the inspector walks the **element tree** as ground truth for type, test ID
and geometry, then **enriches** each node with its corresponding semantics
data. A node is retained if it has a test ID, is a known interesting type
(`Text`, `Image`, `TextField`, buttons, list and scroll containers, toggles),
or carries semantics; otherwise it is flattened and its children re-parented.

Flattening is what keeps the payload small enough to ship on every screen
transition - a raw Flutter element tree for a typical screen is thousands of
nodes, the overwhelming majority of them layout scaffolding.

Bounds are reported in **Flutter logical pixels**, together with
`devicePixelRatio`, so the engine can convert exactly once (see 10.2).

### 9.6 Network capture

A `CaptureAdapter` interface with three implementations:

| Adapter | Mechanism | Notes |
|---|---|---|
| `DioCaptureAdapter` | dio `Interceptor` | Richest metadata: typed request/response, timing, typed errors |
| `HttpCaptureAdapter` | wrapping `http.Client` | Minimal integration effort |
| `HttpOverridesCaptureAdapter` | global `dart:io` `HttpOverrides` | Transparently covers most clients including dio's default adapter |

**Redaction runs at capture time, inside the application process**, before an
event is ever emitted. A secret that never enters an event cannot leak from a
report, a log, or a crash dump. Redacting at report-generation time would be
strictly weaker.

No claim of universal interception is made. The supported matrix is documented
and tested; anything outside it is explicitly listed as unsupported.

## 10. Engine

### 10.1 Device control

```dart
abstract interface class DeviceController {
  Future<DeviceInfo> info();
  Future<AppHandle> launchApp(LaunchSpec spec);
  Future<void> terminateApp(String appId);
  Future<Uint8List> screenshot();
  Future<Size> screenSize();
  Future<void> tap(Offset physical);
  Future<void> longPress(Offset physical, Duration hold);
  Future<void> swipe(Offset from, Offset to, Duration duration);
  Future<void> inputText(String text);
  Future<void> pressBack();
  Future<void> reversePort(int hostPort, int devicePort);
  Future<void> wake();
}
```

`reversePort` and `wake` are on the interface because physical devices need
them and emulators do not: a physical device cannot reach a host-run mock API
at `10.0.2.2` and requires `adb reverse`, and a physical device sleeps and
locks mid-run. Discovering these later would mean bolting them on.

### 10.2 OS-level input, with engine-supplied element awareness (ADR-0006)

`AdbDeviceController` drives real OS input (`adb shell input tap`), the real
back button, and real install and launch. It therefore exercises the genuine
input stack - it can catch a tap that a real overlay swallows, which
in-process event synthesis cannot. Its limitation is that it speaks only
coordinates.

Element awareness is supplied by the **engine**, not the controller: resolve
element ID -> bounds from the UI tree -> tap the centre. This gives
element-level addressing *and* real input rather than trading one for the
other.

An `InProcessDeviceController` (synthesising pointer events through Flutter's
binding via an SDK RPC) is planned for desktop and web targets, where no adb
equivalent exists.

**Read the ratio at use time, not at attach.** Measured on the device: the
handshake completes before the first frame, when the Android view still
reports a default `devicePixelRatio` of 1.0 rather than the true 1.875. A
legitimate 1.0 is indistinguishable from a not-yet-laid-out 1.0, so the SDK
cannot flag it. `ext.mytest.sessionInfo` therefore returns a freshly
resolved `AppContext`, and any coordinate conversion must use that rather
than the value captured at attach. See risk R3b.

**The coordinate-space rule.** UI tree bounds are Flutter *logical* pixels;
`adb shell input` takes *physical* pixels. The SDK reports `devicePixelRatio`
in its handshake and **every** conversion goes through one function. Ad-hoc
multiplication at call sites is prohibited. On the current test device the
ratio is 1.875, so any violation is immediately visible rather than masked.

### 10.3 The Screen Validation Session

```dart
class ScreenSession {
  final String sessionId, screenId;
  final DateTime enteredAt;
  DateTime? exitedAt;
  final List<ApiExchange> apiExchanges;   // request + response, paired
  UiSnapshot? uiSnapshot;
  Uint8List? screenshot;
  FigmaScreenSpec? figmaSpec;             // Phase 5+
  final List<ValidationResult> results;
}
```

This is the correlation core that makes `validateScreen` possible, and it is a
data-correlation problem, not an AI one. Two deterministic rules do the work:

**API-to-screen attribution.** Stated exactly, because ambiguity here is the
classic cause of flaky, unreproducible results. An earlier draft of this
section said only "plus a grace window after SCREEN_ENTER", which turned out
to be too vague to implement from; the rule is:

1. An exchange belongs to the screen current when the **request was
   issued**. Never the response - a slow response arriving after a
   navigation does not move the request to the new screen.
2. **Exception:** a request issued within the grace window (default 2s)
   *before* a screen was entered, and **still unanswered when that screen
   appeared**, is attributed to the new screen. This is the tap handler
   that fetches and then navigates: the data was fetched for the
   destination. Still being in flight at the transition is what
   distinguishes it from a request the old screen merely finished late.
3. A request issued before any screen was entered joins the first screen
   if it falls within the grace window of it - covering app-startup
   fetches - and is otherwise reported as unattributed.

Unattributable exchanges and responses with no matching request are
**reported, never dropped**: silently discarding a request hides it from
the report, and arbitrarily assigning one is a lie.

**Settle detection.** "Is the screen ready to validate?" is answered by a
heuristic, never by `sleep()`: no new frames for a quiet period (default
500ms), **and** zero in-flight
captured requests, **and** no running animations. Exposed as
`waitForSettle(timeout)`. A timeout is reported as a diagnostic naming which
condition never became true - never as a silent pass.

### 10.4 Validation

```dart
class ValidationResult {
  final String validatorId;
  final ValidationStatus status;   // pass | fail | skip | error
  final Severity severity;
  final String? elementId;
  final Object? expected, actual;
  final String message;
  final List<Evidence> evidence;   // screenshot region, api path, figma node
}
```

`skip` and `error` are distinct from `fail` deliberately. "Figma is not
configured" and "the price is wrong" must never render as the same red X;
conflating them trains users to ignore failures.

Validators, added by phase: `ApiSchemaValidator`, `UiPresenceValidator`,
`ApiToUiValidator`, `RulesValidator`, `FigmaStructureValidator`,
`VisualValidator`.

### 10.5 Transformations

A registry of **named, pure** functions: `currency(INR)`, `date(fmt)`,
`boolToEnabled`, `truncate(n)`, `starRating`. Validation compares
`transform(apiValue)` against `uiValue`.

On failure the report shows the **raw API value, the transformed value, and
the UI value**. That triple is what distinguishes a data bug from a formatting
bug, which is exactly the diagnosis the specification's motivating example
demands.

### 10.6 Mapping ownership

`mappings.yaml` per screen: human-owned, git-tracked, the source of truth.

```yaml
screen: ProductDetails
api: GET /products/{id}
mappings:
  - target: product.name
    source: response.name
  - target: product.price
    source: response.price
    transformation: currency(INR)
suggested:          # AI-proposed; inert until promoted by a human
  - target: product.rating
    source: response.rating
    transformation: starRating
    confidence: 0.91
```

Entries under `suggested:` have no effect on a test run. Promotion is a manual
edit. The engine never rewrites this file.

## 10.7 Figma normalisation

Built against a real file rather than an invented one, which changed
three things that a guessed design would have got wrong:

- **Coordinates are canvas-absolute.** The frame this was developed
  against sits at `x = -118574`. Everything is re-expressed relative to
  the frame origin, or every geometry comparison is meaningless.
- **Colour needs two numbers combined.** Figma gives `color` as 0..1
  floats and carries a separate per-fill `opacity`. Both are folded into
  one `#rrggbbaa`, or a 5%-opacity chip reports as solid.
- **Most nodes are not elements.** 119 nodes yielded 91 after dropping
  vector paths and zero-size layers; the rest are icon geometry.

**The node-to-semantic-id mapping layer is mandatory, not a
convenience.** The real frame's layers are named `Frame 42980`,
`Rectangle 91`, `Component 3` and `label-text`. Inferring identifiers
from names would produce something that looks like it works and is
wrong. Mapping is therefore by **node id**, which also survives a
rename, with the layer name and text carried only as a hint for whoever
maintains the file. `testsmith figma pull --write-mapping-template` emits
every candidate as commented lines to fill in or delete, because handing
someone an empty file and a 100KB design is not a workable start.

A mapped node id that is not in the frame is **reported**, so a mapping
left pointing at a deleted layer cannot rot silently.

## 11. Test DSL

YAML, parsed into a **sealed `Step` hierarchy** so the executor's switch is
exhaustively checked.

Unknown keys are a **hard error reporting line and column**, never silently
ignored. A typo'd `expectScreeen:` that quietly does nothing is worse than no
test at all, because it reports green.

## 12. Reporting

`result.json` is written **first**; `report.html` is rendered as a pure
function of it. CI consumes the JSON and the human report therefore can never
disagree with it, and the renderer stays independently testable against
fixtures.

`result.json` carries its own schema version, independent of the protocol
version. It is currently **1.6**. Every raise has been additive except
1.5's one correction, stated below, of a value that was never measured.

A run records its **preconditions** — `fixture`, `appVersion` and `buildMode`
— because every assertion in it was measured against them. `fixture` is the
scenario actually in force, so a run started with `--fixture` records what it
ran against rather than what the flow declared; `appVersion` and `buildMode`
are what the application reported at the handshake, the same values
`suite.json` carries. Each key is omitted when the fact was not known: no
scenario named, or a device that would not say what it was running. Absence
means the run did not record it, never a default standing in for it.

Each entry of `steps[]` carries a `kind` — what the step *was*, taken from
the concrete `Step` in the executor rather than inferred from the
description. The description is presentation text with user-supplied values
interpolated into it, so a report that classified steps by reading it could
be talked into the wrong answer by an element's expected text. The
vocabulary is fixed, and these eleven strings are the contract:

```
launchApp   waitForSettle   tap        input          secretInput   back
expectScreen   expectElement   screenshot   expectApi   validateScreen
```

A consumer reading a file written before 1.3 finds no `kind` and falls back
to whatever it did before; one reading 1.3 uses the field and stops
guessing. A `kind` that is present is authoritative — the description is
never consulted to disagree with it.

### The network record (1.5)

`network` is every request the run captured, run-wide, with a statement
of how much the capture could have seen. It is built at the end of a run
from the correlation the run already performs and from four facts the
connection already holds; nothing is measured for it.

| `capture` | Means |
|---|---|
| `unavailable` | The handshake did not offer the `network` capability. An empty list then says nothing about whether requests were made, and the report says so. |
| `partial` | Capture was on, and the run has evidence of loss: the SDK's startup buffer dropped events, an event could not be decoded, the connection ended, or a response arrived for a request never seen. `reasons` names each. |
| `active` | Capture was on and none of those occurred. Not "complete": `scope` is written into every record and lists what the capture never sees (9.6, R9). |

Each exchange carries the capture's `requestId`, the method, the URL **as
redacted in the application**, the screen the correlator attributed it to
(omitted for none), `requestedAt` and `respondedAt` on the application's
clock, an `outcome` of `success`, `httpError`, `failed` or `unanswered`,
and the status, error and duration that were recorded. No header and no
body is carried, and the renderer would not show one if it were.

Each step carries `startedOffsetMs`, read off the run's monotonic
stopwatch. Steps are timed on the **host**; `requestedAt` is the
**device's** clock, and a run measures no offset between the two. The HTML
timeline is therefore two lanes, each in its own clock's order, and never
one merged list: on the first device run the host's clock was ahead of the
handset's by at least 7.2 s, and a merged list put the login request ahead
of the tap that sent it
([evidence](evidence/schema-1.5-device-run.md)).

The correction: `screens[].exchanges[].durationMs` is omitted for a
request that was never answered. Before 1.5 it was written as `0`.

### Request durations (1.6)

`durationMs` is measured in the application, by `NetworkCapture`, and
travels as a finished number: no clock reading leaves the process.

| | |
|---|---|
| Clock | One `Stopwatch` per capture, injected as `monotonicMicros`. Never the difference of two wall-clock readings. |
| Start | Read before `openUrl`, so DNS, TCP, TLS and a connection timeout are inside the duration. The manual `TestSdk.network.begin` API takes the same reading as `startedAtMicros`, or times from the call. |
| End | The response body fully delivered to the application (`success`, `httpError`), or the error raised (`failed`). Unchanged from 1.5. |
| Units | Whole milliseconds, rounded down. A measured sub-millisecond request is 0; a request with no terminal event has no duration at all. |
| Unanswered | No duration. A response the application abandons and never reads is unanswered, however soon the server replied. |

An SDK that measures this way advertises the `monotonicNetworkTiming`
capability, exactly when it advertises `network`. The CLI reads the
capability from the handshake, never from a version, because an
application pins its own SDK. `network.durationClock` records what it
found:

| `durationClock` | Means |
|---|---|
| `monotonic` | The SDK advertised `monotonicNetworkTiming`. |
| `wall` | It advertised `network` without it: an older SDK, whose durations are wall-clock differences starting after the connection was established. Still captured, still reported, never called monotonic. |
| absent | Capture was `unavailable`, or the file predates 1.6. A reader treats absence as "not recorded", never as either value. |

`requestedAt` and `respondedAt` remain wall-clock stamps on the device,
for display. Their difference is not the duration and nothing computes
it.

The page is self-sufficient: a Content-Security-Policy of
`default-src 'none'` with inline style and one fixed inline script that
shows and hides rows, and no external resource of any kind.

## 13. Security

- Redaction at capture time, in-process (9.6).
- Configurable `sensitiveFields`, header redaction, endpoint exclusion,
  screenshot region masking.
- Strict defaults: `authorization`, `cookie`, `set-cookie`, `password`,
  `token`, `refresh_token`, `access_token`, `cardNumber`, `cvv`, `pin`, `otp`
  are redacted unless explicitly un-redacted.
- Redaction is **allow-by-exception**: an unrecognised field matching a
  sensitive-looking pattern is redacted, and the report notes that it was.
- Response bodies are truncated to `maxBodyBytes` (default 64 KiB), with the
  truncation recorded in the event so no report silently shows partial data.

## 14. Performance

The SDK must not distort what it measures.

- No continuous screenshot capture; screenshots are pull-based via RPC.
- UI tree capture is pull-based and filtered (9.5), not emitted per frame.
- Events are buffered and bounded (8.1).
- Network capture copies bodies up to `maxBodyBytes` and streams past it.
- No widget rebuilds are introduced: `TestKey` is a key, and `TestId` is a
  single lightweight wrapper element.

## 15. Designed-for extension points

These are **not** built now, but the interfaces exist so that adding them is
implementation rather than redesign:

| Future capability | Enabled by |
|---|---|
| Release-mode / device-farm execution | `SdkTransport` interface -> `WebSocketTransport` |
| iOS support | `DeviceController` interface -> `IosDeviceController` |
| Desktop and web targets | `InProcessDeviceController` |
| Cloud backend, dashboard, history | `result.json` as the stable, versioned contract |
| Distributed runners | `ScreenSession` is serialisable and self-contained |

No cloud backend, dashboard, account system or history server is built now,
per specification section 22.

## 16. Architecture decision records

| ADR | Decision |
|---|---|
| [0001](adr/0001-dart-everywhere.md) | Dart for every layer |
| [0002](adr/0002-vm-service-transport.md) | Dart VM Service as primary transport |
| [0003](adr/0003-single-engine-package.md) | One `flutter_testsmith_engine` package, not six |
| [0004](adr/0004-three-tier-test-ids.md) | Three-tier semantic test ID API |
| [0005](adr/0005-hybrid-ui-tree.md) | Hybrid element and semantics tree walk |
| [0006](adr/0006-adb-input.md) | OS-level adb input with engine element resolution |
| [0007](adr/0007-design-projection.md) | Width-fit projection, and skipping vertical checks |
| [0008](adr/0008-visual-comparison.md) | Two gates, measured per element, against a committed baseline |
| [0009](adr/0009-ai-analysis.md) | AI explains, after the verdict, behind a provider seam |
| [0010](adr/0010-screenshot-capture.md) | Two screenshot capture paths, and what each one is for |
| [0011](adr/0011-single-published-package.md) | One published package, `flutter_testsmith`; boundaries move from packages to imports |

---

## 17. The host environment

Sections 1-16 describe the platform's own layers. This one describes its
relationship with the machine it runs on and the application it is
pointed at - which was the whole of the work after Phase 12, and is
where a portability defect now comes from.

The shape of every defect in this area was the same: several commands
each answered one question for themselves, agreed on the development
host, and disagreed the moment the tool was pointed at an application
outside this repository. So each question below has exactly one answer,
in one file, and a second answer is a defect rather than a convenience.

### 17.1 Where the application is

`flutter_testsmith_cli/lib/src/project_root.dart` owns it.

`--app` wins and is taken at its word: a named directory only has to
exist. It is deliberately **not** required to hold a `pubspec.yaml`,
because `generate` and `impact` read configuration rather than build
anything, and refusing them over a missing pubspec would buy a
restriction and no safety.

With nothing named, the root is the nearest ancestor of the working
directory holding a `pubspec.yaml` - the marker `flutter run` itself
looks for, and the only one required. There is never a fallback to a
directory the caller did not name; before this rule existed, five
commands defaulted to `examples/ecommerce_app`, which exists nowhere but
here.

A suite or auth file that declares `app: path:` resolves it relative to
**the declaring file**, so the configuration travels with the
application. An absolute declared path is taken as written.

### 17.2 Where output goes

`flutter_testsmith_cli/lib/src/output_path.dart` owns it, and takes the
root as an argument rather than resolving one - which is what keeps
17.1 the only answer to that question.

> A relative output path is resolved against the resolved application
> root. An absolute one is the directory the caller named.

The root is used exactly as 17.1 handed it over and is not made
absolute: a relative `--app` already means "relative to where I am
standing", and absolutising it here would make the output path disagree
with the application path printed beside it.

### 17.3 External executables

Three tools are invoked as subprocesses: `adb`, `flutter` and `git`.

**adb** (`flutter_testsmith/lib/src/engine/device/adb_location.dart`) is
looked for in one order - `MYTEST_ADB`, then `$ANDROID_HOME/platform-tools`,
then `$ANDROID_SDK_ROOT/platform-tools` (deprecated by Google, and
consulted after for that reason, which is also the order the Flutter tool
uses), then PATH. The result records which source answered and which were
configured but held nothing, so a diagnostic can say "ANDROID_HOME is set
and there is no platform-tools under it" rather than only "adb not found".
Every adb caller resolves through it: two adb versions on one machine run
two servers, and the controller and the environment probe address the same
handset.

**flutter** (`flutter_testsmith/lib/src/engine/environment/flutter_location.dart`)
is **PATH and nothing else**. `FLUTTER_ROOT`, `.fvmrc` and `.fvm/flutter_sdk`
are deliberately not read: PATH is the contract section E-04 already
documents and CI already depends on, and widening it is a policy change
rather than a bug fix. What the resolver adds is that the policy returns
one concrete, absolute executable with its provenance, so `doctor` can
report *which* Flutter it measured.

Two host-specific rules are load-bearing rather than incidental:

- On Windows the candidates are only the runnable wrappers
  (`flutter.bat`, `flutter.cmd`, `flutter.exe`). The extensionless
  `bin/flutter` is a POSIX shell script that exists on a Windows install
  and will not run; Dart's `Process` API does not consult `PATHEXT`, so
  existence is the right question only once the filename can be trusted.
- The resolved path is made absolute. A relative PATH entry was validated
  against the directory the CLI started in and then run against
  `AppSession.launch`'s working directory - a different SDK, silently, or
  an eight-minute launch timeout with nothing said.

**git** is used by impact analysis. A tool that will not launch is
reported as something to install; it is never an unhandled
`ProcessException`, which exited 255 and put an absolute application
path into whatever the output was piped to.

### 17.4 Credentials

The process environment first, then the first `.env` found beside the
application, then the one beside the caller. The real environment always
wins, so CI is never overridden by a developer's local file.

`dotenv.dart` is deliberately minimal - no interpolation, no exports, no
multi-line values - because a secrets parser with features is a secrets
parser with somewhere for a mistake to hide. `secrets/env_secret_resolver.dart`
resolves an `env:NAME` reference and returns a `Secret`, never a bare
`String`. Every credential-reading command builds the same resolver; see
`.env.example` for the variables and `secret_ref.dart` for the reference
syntax.

### 17.5 Application identity

A flow declares `appId:` and the runner asserts it against the device
before force-stopping anything, because `am force-stop` succeeds for a
package that is not installed - so a wrong value leaves the real
application running and breaks the next run. `inspect` and `smoke`, which
have no flow to read, require `--app-id`.

The device probe distinguishes three answers, not two: installed, not
installed, and *could not ask*. An offline or unauthorised handset makes
`pm list packages` exit non-zero with empty stdout, and reading that
emptiness as an answer produced a claim about somebody's application from
a question that was never asked.

### 17.6 Reading a project's configuration

`flutter_testsmith_cli/lib/src/project_config.dart` indexes a directory of
files by the screen each one names, and is shared by `run` and
`suite run` so a screen's mappings and design resolve identically either
way. A suite that read them differently would be a second definition of
what a project is.

Two files naming one screen are **refused**. A second file used to
replace the first, and because files arrive in `Directory.listSync()`
order - which `dart:io` does not specify and which differs by filesystem
- which configuration survived was a property of the machine. A project
could validate against one mapping locally and the other in CI, and
report success both times. This is the same rule as everywhere else in
the platform: it does not guess between candidates, not between devices,
not between duplicate test ids, and not here.
