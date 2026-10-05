# flutter_testsmith_protocol

The versioned wire contract of Flutter Testsmith, shared verbatim by the
in-app SDK (`flutter_testsmith`) and the out-of-process engine
(`flutter_testsmith_engine`).

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
  flutter_testsmith  ──── VM Service ────  flutter_testsmith_engine
          └──────── flutter_testsmith_protocol ────────┘
```

This package is linked into applications through `flutter_testsmith`, so
anything it depends on becomes a dependency of every application under
test. It therefore depends on nothing but `meta`, and never on Flutter.

## Do you need to depend on it?

Usually not. `flutter_testsmith` re-exports this package in full, so an
application adds `flutter_testsmith` and nothing else. Depend on it
directly only if you are writing your own engine-side tooling that reads
Testsmith events:

```yaml
dependencies:
  flutter_testsmith_protocol: ^0.1.1
```

```dart
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

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
