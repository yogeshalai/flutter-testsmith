import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

import 'support/fake_sdk_channel.dart';

const AppContext app = AppContext(
  appVersion: '1.0.0',
  buildMode: BuildMode.debug,
  environment: 'test',
  platform: 'android',
  devicePixelRatio: 1.875,
);

({TestSdkRuntime runtime, List<FakeSdkChannel> channels}) start({
  TestSdkConfig config = const TestSdkConfig(enabled: true),
  bool isReleaseMode = false,
}) {
  final channels = <FakeSdkChannel>[];
  final runtime = TestSdkRuntime.start(
    config: config,
    describeApp: () => app,
    appId: 'com.example.shop',
    sdkVersion: '0.1.0',
    isReleaseMode: isReleaseMode,
    channelFactory: () {
      final channel = FakeSdkChannel();
      channels.add(channel);
      return channel;
    },
  );
  return (runtime: runtime, channels: channels);
}

void main() {
  group('when armed', () {
    test('creates a session and announces it', () {
      final (:runtime, :channels) = start();

      expect(runtime.isArmed, isTrue);
      expect(runtime.decision, ArmDecision.armed);
      expect(runtime.session, isNotNull);
      expect(channels.single.emitted.single.type, EventType.sessionStart);
    });

    test('serves the Phase 1 RPCs', () {
      final (:runtime, :channels) = start();

      expect(
        channels.single.handlers.keys,
        containsAll(<String>[
          'ext.mytest.handshake',
          'ext.mytest.ping',
          'ext.mytest.sessionInfo',
        ]),
      );
    });

    test('stops by emitting SESSION_END and closing the channel', () async {
      final (:runtime, :channels) = start();

      await runtime.stop(SessionEndReason.completed);

      expect(channels.single.emitted.last.type, EventType.sessionEnd);
      expect(channels.single.closed, isTrue);
    });
  });

  group('when disabled by config', () {
    test('creates no session', () {
      final (:runtime, :channels) = start(config: const TestSdkConfig());

      expect(runtime.isArmed, isFalse);
      expect(runtime.decision, ArmDecision.disabledByConfig);
      expect(runtime.session, isNull);
    });

    test('never opens a channel at all', () {
      // Not merely "emits nothing" - the channel is never constructed, so
      // no service extension is registered and nothing is observable from
      // outside the process.
      final (:runtime, :channels) = start(config: const TestSdkConfig());

      expect(channels, isEmpty);
    });

    test('stopping is a harmless no-op', () async {
      final runtime = start(config: const TestSdkConfig()).runtime;

      await expectLater(runtime.stop(SessionEndReason.completed), completes);
    });
  });

  group('when the build is a release build', () {
    test('refuses to arm without an explicit opt-in', () {
      final (:runtime, :channels) = start(
        config: const TestSdkConfig(enabled: true),
        isReleaseMode: true,
      );

      expect(runtime.decision, ArmDecision.blockedInRelease);
      expect(runtime.session, isNull);
      expect(channels, isEmpty);
    });

    test('arms with an explicit opt-in', () {
      final (:runtime, :channels) = start(
        config: const TestSdkConfig(enabled: true, allowInRelease: true),
        isReleaseMode: true,
      );

      expect(runtime.decision, ArmDecision.armed);
      expect(runtime.session, isNotNull);
      expect(channels, hasLength(1));
    });
  });

  group('configuration errors', () {
    test('an invalid config fails before anything is constructed', () {
      expect(
        () => start(
          config: const TestSdkConfig(enabled: true, eventBufferSize: 0),
        ),
        throwsArgumentError,
      );
    });
  });
}
