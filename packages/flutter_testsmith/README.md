# flutter_testsmith

In-application instrumentation for Flutter Testsmith, a testing platform
that validates the whole chain behind a screen: API request, API
response, app state, widget tree, UI field values, Figma design,
screenshot and visual comparison.

This is the only package an application under test adds. It records
what the application is doing and serves it over the Dart VM Service to
the out-of-process engine (`package:flutter_testsmith/engine.dart`, driven
by the `testsmith` CLI; both are part of this package). The SDK makes no
verdicts of its own, and it never links the engine: nothing your
application imports reaches the testing logic.

## What it captures

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
capture**, in-process, before an event is emitted.

## Installation

```yaml
dependencies:
  flutter_testsmith: ^0.1.3
```

It is a regular dependency, not a dev dependency, because the
instrumentation runs inside the built application. In a release build it
compiles out; see *Production safety* below.

## Usage

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

## Production safety

Three independent layers keep the instrumentation out of a shipped
application:

1. `enabled` is a compile-time constant the tree-shaker acts on.
2. A runtime guard refuses to arm in a release build unless
   `allowInRelease` is set explicitly.
3. The Dart VM Service the engine talks to does not exist in release
   builds at all.

## Limitations

- **Android** is the only platform verified on a device. Nothing here is
  Android-specific, but iOS has not been measured.
- Network capture sees `dart:io` `HttpClient` traffic only. Custom dio
  adapters, web fetch, HTTP performed natively by a plugin, gRPC and
  WebSockets are not seen automatically; such applications can report
  traffic through `NetworkCapture` directly.
- An `HttpOverrides.global` the application installed before
  `initialize` is kept and wrapped, not replaced.

## Status

Pre-release (0.x). The API may still change between minor versions.
