## 0.1.4

- First publication on pub.dev. `flutter_testsmith` is now the whole of
  Flutter Testsmith in one package: the in-app SDK, the `testsmith`
  executable (`dart run flutter_testsmith:testsmith`), and the protocol,
  engine, Figma and AI components. Until now these components were
  separate packages in the repository, none of them published; their
  public libraries are now `package:flutter_testsmith/protocol.dart`,
  `engine.dart`, `figma.dart` and `ai.dart`, with the same exports as
  before.
- The SDK's public API is unchanged: the same import,
  `package:flutter_testsmith/flutter_testsmith.dart`, with the same
  exports, including the protocol it re-exports.
- 0.1.3 was a source pre-release in the GitHub repository and was not
  published to pub.dev.

## 0.1.3

- Initial pre-release. In-app instrumentation for Flutter Testsmith:
  `TestSdk.initialize`, `TestKey` semantic ids, navigation tracking,
  UI tree inspection, `dart:io` network capture with redaction at
  capture, surface screenshots, and three-layer release gating.
  Android is the only platform verified on a device. The 0.x series may
  still change its API between minor versions.
