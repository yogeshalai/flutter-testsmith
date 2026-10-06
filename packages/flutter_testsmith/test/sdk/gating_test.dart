import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  group('decideArming', () {
    test('arms when enabled in a debug build', () {
      expect(
        decideArming(
          configEnabled: true,
          isReleaseMode: false,
          allowInRelease: false,
        ),
        ArmDecision.armed,
      );
    });

    test('stays disabled when the config says so, even in debug', () {
      expect(
        decideArming(
          configEnabled: false,
          isReleaseMode: false,
          allowInRelease: false,
        ),
        ArmDecision.disabledByConfig,
      );
    });

    test('refuses to arm in a release build by default', () {
      // The runtime guard. Layer 1 (a compile-time constant) should already
      // have removed the instrumentation; this catches a mis-gated build.
      expect(
        decideArming(
          configEnabled: true,
          isReleaseMode: true,
          allowInRelease: false,
        ),
        ArmDecision.blockedInRelease,
      );
    });

    test('arms in release only with an explicit opt-in', () {
      expect(
        decideArming(
          configEnabled: true,
          isReleaseMode: true,
          allowInRelease: true,
        ),
        ArmDecision.armed,
      );
    });

    test('config disabled beats a release opt-in', () {
      expect(
        decideArming(
          configEnabled: false,
          isReleaseMode: true,
          allowInRelease: true,
        ),
        ArmDecision.disabledByConfig,
      );
    });

    test('only the armed decision permits instrumentation', () {
      expect(ArmDecision.armed.isArmed, isTrue);
      expect(ArmDecision.disabledByConfig.isArmed, isFalse);
      expect(ArmDecision.blockedInRelease.isArmed, isFalse);
    });

    test('every non-armed decision explains itself', () {
      for (final decision in ArmDecision.values) {
        if (!decision.isArmed) {
          expect(decision.explanation, isNotEmpty);
        }
      }
    });
  });

  group('TestSdkConfig', () {
    test('is disabled by default so an accidental include is inert', () {
      const config = TestSdkConfig();
      expect(config.enabled, isFalse);
    });

    test('reports the capabilities it has switched on', () {
      const config = TestSdkConfig(
        enabled: true,
        enableNavigationTracking: true,
        enableUiInspection: false,
        enableNetworkCapture: true,
      );

      expect(config.capabilities, containsAll(<String>['navigation', 'network']));
      expect(config.capabilities, isNot(contains('uiTree')));
    });

    test('reports no capabilities when disabled', () {
      const config = TestSdkConfig(
        enableNavigationTracking: true,
        enableUiInspection: true,
      );

      expect(config.capabilities, isEmpty);
    });

    test('rejects a non-positive event buffer size', () {
      expect(
        () => TestSdkConfig(enabled: true, eventBufferSize: 0).validate(),
        throwsArgumentError,
      );
    });

    test('rejects a negative body byte limit', () {
      expect(
        () => TestSdkConfig(enabled: true, maxBodyBytes: -1).validate(),
        throwsArgumentError,
      );
    });

    test('accepts the documented defaults', () {
      expect(() => const TestSdkConfig(enabled: true).validate(), returnsNormally);
      expect(const TestSdkConfig().eventBufferSize, 500);
      expect(const TestSdkConfig().maxBodyBytes, 64 * 1024);
    });
  });
}
