# flutter_testsmith

End-to-end testing for Flutter that validates the whole chain behind a
screen: API request, API response, app state, widget tree, UI field
values, Figma design, screenshot and visual comparison. When a check
fails, a language model can explain why, after the verdict and never in
place of it.

One package holds both halves:

- **the SDK**, which the application under test adds. It records what
  the application is doing and serves it over the Dart VM Service;
- **the `testsmith` CLI** and the engine behind it, which run on the
  testing machine, drive the application on an Android device and
  decide whether each screen is right.

The SDK never links the testing side. Nothing your application imports
reaches engine, CLI, Figma or AI code.

## Installation

```yaml
dependencies:
  flutter_testsmith: ^0.1.4
```

or `flutter pub add flutter_testsmith`.

It is a regular dependency, not a dev dependency, because the
instrumentation runs inside the built application. In a release build it
compiles out; see *Production safety* below. The same dependency provides
the CLI and the component libraries; there is nothing else to add.

## The SDK

### What it captures

- **Navigation**: route changes, through a `NavigatorObserver`
- **Semantic test ids**: `TestKey('product.price')`, dotted lowercase,
  found by id rather than by text or position
- **The UI tree**: a filtered snapshot of the widgets worth asserting on,
  with geometry, text, typography and colour
- **Network traffic**: `dart:io` HTTP, which covers `package:http`'s
  `IOClient` and dio's default adapter, with no change to application code
- **Screenshots** of the application's own surface, on request

Request and response bodies are truncated to a configurable size, and
sensitive headers, query parameters and body fields are redacted **at
capture**, in-process, before an event is emitted. The SDK makes no
verdicts of its own.

### Usage

Initialise as early as possible:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await TestSdk.initialize(
    appId: 'com.example.shop',
    config: const TestSdkConfig(
      // A compile-time constant, so release builds tree-shake the
      // instrumentation away entirely.
      enabled: bool.fromEnvironment('TEST_MODE'),
    ),
  );

  runApp(const MyApp());
}
```

Then attach the observer and mark the elements worth asserting on:

```dart
MaterialApp(
  navigatorObservers: [TestSdk.navigatorObserver], // inert when not armed
  home: Text(product.name, key: const TestKey('product.name')),
)
```

Build with `--dart-define=TEST_MODE=true` to arm it. The `testsmith` CLI
does this for you when it launches the application.

`TestSdkConfig` turns individual capabilities off (`enableNetworkCapture`,
`enableUiInspection`, `enableScreenshots`, `enableNavigationTracking`) and
sets the `RedactionPolicy`, body size limit and startup event buffer size.

### Production safety

Three independent layers keep the instrumentation out of a shipped
application:

1. `enabled` is a compile-time constant the tree-shaker acts on.
2. A runtime guard refuses to arm in a release build unless
   `allowInRelease` is set explicitly.
3. The Dart VM Service the engine talks to does not exist in release
   builds at all.

## The CLI

The package provides the `testsmith` executable. Run it from the
directory of the application that depends on `flutter_testsmith`:

```bash
dart run flutter_testsmith:testsmith doctor
dart run flutter_testsmith:testsmith run tests/product.yaml -d <serial>
```

`dart run flutter_testsmith:testsmith` is the supported invocation.
`dart pub global activate flutter_testsmith` also installs a `testsmith`
launcher, but pub does not run global executables of packages that need
the Flutter SDK except from the snapshot built at activation, so that
launcher has to be activated again after every Dart SDK upgrade.

### Requirements

- `flutter` on `PATH`. It is found there and nowhere else.
- `adb`, found from `MYTEST_ADB`, then `ANDROID_HOME`, then
  `ANDROID_SDK_ROOT`, then `PATH`. `doctor` reports which one was used.
- An attached Android device or emulator for anything that runs the
  application.

### Commands

| Command | Does |
|---|---|
| `doctor` | Check that this machine has everything needed to run tests |
| `devices` | List attached Android devices and emulators |
| `preflight` | Check that this environment can run a suite, before it runs one |
| `smoke` | Launch the app, attach over the VM Service, and verify the channel |
| `inspect` | Capture and print the semantic UI tree of the current screen |
| `run` | Run a test flow and write a report |
| `suite run` | Run every flow a suite declares, in order |
| `auth setup` | Sign in on the device through the real login UI, and verify it |
| `figma pull` | Fetch a frame and normalise it into a design specification |
| `impact` | Show which test flows a set of changes makes worth running |
| `generate` | Propose edge-case test scenarios, which never run until a person accepts them |

`dart run flutter_testsmith:testsmith help <command>` lists every option.

### A flow

```yaml
# tests/product.yaml
appId: com.example.shop
flow: product_details

steps:
  - launchApp
  - waitForSettle
  - tap:
      id: home.open_product
  - expectScreen:
      id: /product/details
  - waitForSettle
  - validateScreen
```

`validateScreen` runs every check that has configuration and reports why
any other could not run, rather than going quiet. `run` writes
`result.json` and `report.html`. Project assets live beside the
application: `mappings/`, `tests/`, `figma/`, `auth/`, `device_profiles/`,
`visual_baselines/` and `mock_api/`.

### Exit codes

| Code | Means |
|---|---|
| 0 | Passed. Checks reported as `skip` say why they could not be made. |
| 1 | A check failed: the application did something wrong. |
| 2 | Nothing could be evaluated: environment, configuration, device or connection. Not a test failure. |

More: [doc/cli.md](doc/cli.md).

## Component libraries

Besides the SDK, the package has four public libraries. An application
needs none of them: the SDK import and the CLI are the whole of normal
use. They are public for tooling built on the same wire format, flow
format, validators and reports.

| Import | Component | Use |
|---|---|---|
| `package:flutter_testsmith/protocol.dart` | Protocol | The versioned wire contract between the SDK and the engine. The SDK library re-exports it in full; import it alone only for engine-side tooling, which must not pull in Flutter. [doc/protocol.md](doc/protocol.md) |
| `package:flutter_testsmith/engine.dart` | Engine | Transport, device control, the flow DSL, preflight, validators, impact analysis and reports: the brain behind the CLI. [doc/engine.md](doc/engine.md) |
| `package:flutter_testsmith/figma.dart` | Figma | Fetches Figma frames and normalises them into a design specification. Usually used through `testsmith figma pull`. [doc/figma.md](doc/figma.md) |
| `package:flutter_testsmith/ai.dart` | AI | Provider-agnostic access to an OpenAI-compatible chat completion model, which the engine uses to explain failures and propose tests. [doc/ai.md](doc/ai.md) |

The protocol, engine, Figma and AI libraries are pure Dart: their code
never imports Flutter.

## Architecture

SDK, Protocol, Engine, CLI, Figma and AI are components of this one
package, not separate packages to install. Their separation is kept by
import rules rather than package boundaries, and checked in the
repository on every change:

- nothing reachable from `lib/flutter_testsmith.dart` imports engine,
  CLI, Figma or AI code, so the application under test never links the
  testing brain;
- protocol, engine, CLI, Figma and AI code never reaches Flutter, so the
  engine's logic is unit tested without a Flutter harness.

**The deterministic engine decides. AI explains, suggests and
prioritises.** A pass/fail verdict never carries a confidence score, AI
analysis runs on a finished result and never changes it, a model outage
is reported as *unavailable* rather than as a failure, and request and
response bodies are never sent to a model.

## Example

[`examples/ecommerce_app`](https://github.com/yogeshalai/flutter-testsmith/tree/main/examples/ecommerce_app)
in the repository is a Flutter application that depends on
`flutter_testsmith`. Its application code imports only the SDK; its
flows, mappings, Figma specifications, mock API scenarios and visual
baselines sit beside it in the layout above, and its tests drive the
engine's validators over its real widgets. It is not part of the
published package.

## Limitations

- **Android** is the only platform verified on a device. Nothing in the
  SDK is Android-specific, but iOS has not been measured. The CLI drives
  Android only, one device per invocation.
- Network capture sees `dart:io` `HttpClient` traffic only. Custom dio
  adapters, web fetch, HTTP performed natively by a plugin, gRPC and
  WebSockets are not seen automatically; such applications can report
  traffic through `NetworkCapture` directly.
- An `HttpOverrides.global` the application installed before
  `initialize` is kept and wrapped, not replaced.
- Visual baselines are per device resolution, and are never re-recorded
  unless you pass `--update-visual-baselines`.

## Development

In a clone of the
[repository](https://github.com/yogeshalai/flutter-testsmith):

```bash
dart pub get                                # one resolve, whole workspace
dart run scripts/check_dependencies.dart    # the layering rules, first
dart analyze --fatal-infos

cd packages/flutter_testsmith
dart test test/protocol
dart test test/engine
dart test test/cli
dart test test/figma
dart test test/ai
flutter test test/sdk
```

## Status

Pre-release (0.x). The API, CLI flags and output formats may still change
between minor versions.
