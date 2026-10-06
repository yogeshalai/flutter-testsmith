# The engine (`package:flutter_testsmith/engine.dart`)

The out-of-process engine of Flutter Testsmith. It drives a Flutter
application on a device, talks to the in-app SDK
(`package:flutter_testsmith/flutter_testsmith.dart`) over the Dart VM
Service, and decides whether a screen is right.

Until ADR-0011 it was its own package, `flutter_testsmith_engine`. It now
lives in `lib/src/engine/` of `flutter_testsmith`, and this page was that
package's README.

Most people should not import it directly. It is the brain behind the
`testsmith` command-line tool, and that is the supported way to run
tests. Import the engine only to build your own tooling on the same flow
format, validators and reports.

## What it owns

| Area | Contents |
|---|---|
| Transport | `flutter run --machine`, VM Service attach, handshake, event recovery |
| Device | adb discovery and control, device profiles, surface screenshots |
| DSL | flows (`TestFlow`), suites, steps, named API fixture scenarios, auth flows |
| Environment | preflight: can this machine evaluate anything before a suite spends minutes finding out |
| Validation | UI presence, API-to-UI values with declared transformations, business rules, Figma structure, geometry, order, typography and colour, visual regression |
| Impact | which flows a change makes worth running, from git and a project index |
| Reporting | `result.json`, `suite.json`, HTML reports, per-dimension verdicts, the network record |
| AI | post-verdict failure analysis and proposed tests, through `ai_client` |

## The governing rule

**The deterministic engine decides. AI explains, suggests and
prioritises.** A pass/fail verdict never carries a confidence score. AI
analysis runs on a finished result and returns an annotated copy, so no
model output can reach a verdict. A model outage is reported as
*unavailable*, never as a test failure, and request and response bodies
are never sent to a model.

Three related rules run through every validator:

- `skip` is not `pass`. A check that cannot honestly be made says why.
- An environment that cannot be evaluated is not a failure: it is
  reported separately, and the CLI exits 2 rather than 1.
- Visual baselines are never re-recorded automatically.

## Installation

It comes with `flutter_testsmith`; there is nothing extra to add:

```dart
import 'package:flutter_testsmith/engine.dart';
```

Pure Dart. Its code never imports Flutter (rule B in
`scripts/check_dependencies.dart`), which is what lets the CLI compile to
a native executable and lets validators be unit tested in milliseconds.
Running against a device needs `flutter` on `PATH` and
`adb` (`MYTEST_ADB`, `ANDROID_HOME`, `ANDROID_SDK_ROOT` or `PATH`).

## Example

Reading a flow, the same way `testsmith run` does:

```dart
import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

void main() {
  const path = 'tests/product.yaml';
  final flow = TestFlow.parse(File(path).readAsStringSync(), source: path);
  print('${flow.name} drives ${flow.appId} in ${flow.steps.length} steps');
}
```

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

A flow stamped `status: proposed`, which is what the test generator
writes, is refused by `run` and `suite run` until a person approves it by
editing the file. `--allow-proposed` runs one for review; it is not
approval.

## Limitations

- Android only. Device control is behind a `DeviceController` interface,
  but `AdbDeviceController` is the only implementation.
- `flutter` is found on `PATH` and nowhere else; `FLUTTER_ROOT` and FVM
  are deliberately not consulted.

## Status

Pre-release (0.x). The API may still change between minor versions.
