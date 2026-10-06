import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Lines captured verbatim from a real `flutter run --machine` against the
/// Samsung SM-M127G on 2026-09-10. Using real output rather than an
/// invented format is the point: the parser is only worth anything if it
/// handles what the tool actually emits, interleaved noise included.
const String daemonConnected =
    '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":10688}}]';

const String appStart = '[{"event":"app.start","params":{"appId":'
    '"9ea1b70a-6442-48d3-aa1f-4c55b660a953","deviceId":"RZ8T11QETWM",'
    '"directory":"D:\\\\Repositories\\\\flutter-ai-test-platform\\\\examples'
    '\\\\ecommerce_app","supportsRestart":true,"launchMode":"run",'
    '"mode":"debug"}}]';

const String appDebugPort = '[{"event":"app.debugPort","params":{"appId":'
    '"9ea1b70a-6442-48d3-aa1f-4c55b660a953","port":50792,'
    '"wsUri":"ws://127.0.0.1:50792/u97OFun37v4=/ws",'
    '"baseUri":"file:///data/user/0/com.example.ecommerce_app/code_cache/"}}]';

const String appStarted = '[{"event":"app.started","params":{"appId":'
    '"9ea1b70a-6442-48d3-aa1f-4c55b660a953"}}]';

const String appProgress = '[{"event":"app.progress","params":{"appId":'
    '"9ea1b70a-6442-48d3-aa1f-4c55b660a953","id":"0","progressId":null,'
    '"message":"Running Gradle task \'assembleDebug\'...","finished":false}}]';

const String appStop = '[{"event":"app.stop","params":{"appId":'
    '"9ea1b70a-6442-48d3-aa1f-4c55b660a953"}}]';

// The tool interleaves plenty of this.
const List<String> noiseLines = [
  'Launching lib\\main.dart on SM M127G in debug mode...',
  '√ Built build\\app\\outputs\\flutter-apk\\app-debug.apk',
  'D/FlutterJNI(18136): Beginning load of flutter...',
  'I/Choreographer(18136): Skipped 379 frames!',
  '',
  '   ',
  'Resolving dependencies in `D:\\Repositories\\flutter-ai-test-platform`...',
];

void main() {
  group('FlutterMachineEvent.tryParse', () {
    test('parses a daemon event', () {
      final event = FlutterMachineEvent.tryParse(daemonConnected);

      expect(event, isNotNull);
      expect(event!.event, 'daemon.connected');
      expect(event.params['pid'], 10688);
    });

    test('parses app.debugPort including the websocket uri', () {
      final event = FlutterMachineEvent.tryParse(appDebugPort)!;

      expect(event.event, 'app.debugPort');
      expect(event.params['wsUri'], 'ws://127.0.0.1:50792/u97OFun37v4=/ws');
      expect(event.params['port'], 50792);
    });

    test('returns null for every kind of non-event line', () {
      for (final line in noiseLines) {
        expect(
          FlutterMachineEvent.tryParse(line),
          isNull,
          reason: 'should have ignored: $line',
        );
      }
    });

    test('returns null rather than throwing on malformed JSON', () {
      // The tool can be interrupted mid-line; a crash here would lose the
      // whole run for a cosmetic reason.
      expect(FlutterMachineEvent.tryParse('[{"event":'), isNull);
      expect(FlutterMachineEvent.tryParse('{"event":"x"}'), isNull);
      expect(FlutterMachineEvent.tryParse('[]'), isNull);
      expect(FlutterMachineEvent.tryParse('[1,2,3]'), isNull);
      expect(FlutterMachineEvent.tryParse('[{"no_event":true}]'), isNull);
    });
  });

  group('FlutterRunSession', () {
    test('captures the app id from app.start', () {
      final session = FlutterRunSession()..consume(appStart);

      expect(session.appId, '9ea1b70a-6442-48d3-aa1f-4c55b660a953');
      expect(session.deviceId, 'RZ8T11QETWM');
    });

    test('captures the websocket uri from app.debugPort', () {
      final session = FlutterRunSession()..consume(appDebugPort);

      expect(session.vmServiceUri.toString(),
          'ws://127.0.0.1:50792/u97OFun37v4=/ws');
    });

    test('is not ready until both the uri and app.started have arrived', () {
      final session = FlutterRunSession();
      expect(session.isReady, isFalse);

      session.consume(appDebugPort);
      expect(session.isReady, isFalse,
          reason: 'a debug port alone does not mean the app is running');

      session.consume(appStarted);
      expect(session.isReady, isTrue);
    });

    test('completes its ready future once the app has started', () async {
      final session = FlutterRunSession()
        ..consume(appDebugPort)
        ..consume(appStarted);

      await expectLater(session.onReady, completes);
      expect((await session.onReady).toString(), contains('50792'));
    });

    test('survives the full real transcript in order', () {
      final session = FlutterRunSession();

      for (final line in [
        'Resolving dependencies...',
        daemonConnected,
        appStart,
        'Launching lib\\main.dart on SM M127G in debug mode...',
        appProgress,
        '√ Built build\\app\\outputs\\flutter-apk\\app-debug.apk',
        'D/FlutterJNI(18136): Beginning load of flutter...',
        appDebugPort,
        appStarted,
        'I/Choreographer(18136): Skipped 379 frames!',
      ]) {
        session.consume(line);
      }

      expect(session.isReady, isTrue);
      expect(session.appId, '9ea1b70a-6442-48d3-aa1f-4c55b660a953');
      expect(session.deviceId, 'RZ8T11QETWM');
      expect(session.vmServiceUri.toString(), contains('50792'));
      expect(session.hasStopped, isFalse);
    });

    test('notices app.stop', () {
      final session = FlutterRunSession()
        ..consume(appDebugPort)
        ..consume(appStarted)
        ..consume(appStop);

      expect(session.hasStopped, isTrue);
    });

    test('throws a clear error when the uri is read before it arrives', () {
      expect(
        () => FlutterRunSession().vmServiceUri,
        throwsA(isA<StateError>()),
      );
    });
  });
}
