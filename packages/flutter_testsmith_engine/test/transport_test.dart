import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  group('selectSdkIsolate', () {
    test('picks the isolate serving the testsmith extensions', () {
      final id = selectSdkIsolate({
        'isolates/1': ['ext.flutter.reassemble'],
        'isolates/2': ['ext.dart.io.getVersion', 'ext.mytest.handshake'],
      });

      expect(id, 'isolates/2');
    });

    test('picks the first match when several isolates qualify', () {
      final id = selectSdkIsolate({
        'isolates/1': ['ext.mytest.ping'],
        'isolates/2': ['ext.mytest.ping'],
      });

      expect(id, 'isolates/1');
    });

    test('explains what to do when no isolate has the SDK', () {
      // The overwhelmingly likely cause is a missing dart-define, so the
      // error says so rather than reporting a bare "not found".
      expect(
        () => selectSdkIsolate({
          'isolates/1': ['ext.flutter.reassemble'],
        }),
        throwsA(
          isA<SdkNotFoundException>()
              .having((e) => e.toString(), 'message', contains('TEST_MODE'))
              .having(
                (e) => e.toString(),
                'message',
                contains('TestSdk.initialize'),
              ),
        ),
      );
    });

    test('explains the empty case too', () {
      expect(
        () => selectSdkIsolate(const {}),
        throwsA(isA<SdkNotFoundException>()),
      );
    });

    test('ignores an isolate whose extensions merely look similar', () {
      expect(
        () => selectSdkIsolate({
          'isolates/1': ['ext.mytestimposter.ping', 'ext.my.test.ping'],
        }),
        throwsA(isA<SdkNotFoundException>()),
      );
    });
  });
}
