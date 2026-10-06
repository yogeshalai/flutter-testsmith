// The SDK's public surface must be closed.
//
// An application outside this monorepo adds `flutter_testsmith` and nothing else.
// If a type in flutter_testsmith's public API comes from `flutter_testsmith_protocol` and is not
// re-exported, that application cannot name it without adding an internal
// platform package to its own pubspec — which is finding E-01 wearing a
// different hat.
//
// This file therefore imports **only** `package:flutter_testsmith/flutter_testsmith.dart`.
// Adding an import of `package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart` here
// would defeat the entire point: the test passes by compiling.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  test('every protocol type in the public API is reachable through '
      'flutter_testsmith alone', () {
    // Each of these appears in the signature of something flutter_testsmith
    // exports. Naming them here is the assertion.
    expect(AppContext, isNotNull);
    expect(AnimationActivity, isNotNull);
    expect(EventPayload, isNotNull);
    expect(HandshakeRequest, isNotNull);
    expect(HandshakeResponse, isNotNull);
    expect(LogicalRect, isNotNull);
    expect(ScreenEnterPayload, isNotNull);
    expect(ScreenExitPayload, isNotNull);
    expect(SessionEndPayload, isNotNull);
    expect(SessionEndReason, isNotNull);
    expect(TestEvent, isNotNull);
    expect(UiNode, isNotNull);
    expect(UiSnapshot, isNotNull);
    expect(WidgetTreePayload, isNotNull);
  });

  test('the protocol version is reachable, so a consumer can report it', () {
    expect(ProtocolVersion.current.value, isNotEmpty);
  });
}
