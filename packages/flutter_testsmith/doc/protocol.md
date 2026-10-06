# The protocol (`package:flutter_testsmith/protocol.dart`)

The versioned wire contract of Flutter Testsmith, shared verbatim by the
in-app SDK (`package:flutter_testsmith/flutter_testsmith.dart`) and the
out-of-process engine (`package:flutter_testsmith/engine.dart`).

Until ADR-0011 it was its own package, `flutter_testsmith_protocol`. It now
lives in `lib/src/protocol/` of `flutter_testsmith`, and this page was that
package's README. Its Dart API and the wire format are unchanged.

It defines what crosses the Dart VM Service between an application under
test and the machine testing it:

- `TestEvent`, the event envelope, and `decodeTestEvent`, which tells an
  event this build understands apart from one it should ignore or cannot
  decode
- `HandshakeRequest` / `HandshakeResponse`, which agree a protocol version
  and the capabilities the application actually serves
- `UiSnapshot` and the geometry types a captured widget tree is made of
- `AppContext`, payload types, animation records and protocol errors
- `ProtocolVersion`, a `major.minor` version where compatibility is
  decided by the major component alone

## Where it sits

```
application under test                      testing machine
  SDK (flutter_testsmith.dart) ── VM Service ── engine (engine.dart)
          └──────────── protocol (protocol.dart) ────────────┘
          all three inside the one package, flutter_testsmith
```

The protocol is linked into applications through the SDK, so anything it
reaches becomes part of every application under test. Its code therefore
imports nothing but `meta` and `dart:convert`, and never Flutter
(`scripts/check_dependencies.dart`, rule B).

## Do you need to import it?

Usually not. The SDK library re-exports the protocol in full, so an
application imports `package:flutter_testsmith/flutter_testsmith.dart` and
nothing else. Import the protocol library on its own only if you are
writing engine-side tooling that reads Testsmith events, where pulling in
the SDK library (which needs Flutter) would be wrong:

```dart
import 'package:flutter_testsmith/protocol.dart';

void main() {
  final theirs = ProtocolVersion.parse('1.3');
  if (!ProtocolVersion.current.isCompatibleWith(theirs)) {
    throw StateError('engine speaks ${ProtocolVersion.current.value}, '
        'application speaks ${theirs.value}');
  }
}
```

## Compatibility

A major-version mismatch is refused rather than degraded: a protocol that
silently drops what it does not understand produces wrong test results
rather than an obvious error. The VM Service extension namespace is
`ext.mytest.*` and is frozen; renaming it would itself be a protocol
change.

## Status

Pre-release (0.x). The API may still change between minor versions.
