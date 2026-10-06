// Brief item 9 - what auth setup leaves on disk.
//
// Every assertion searches the serialised text for the literal, because
// the failure being guarded against is a route nobody thought of, not a
// field somebody forgot to redact. Same discipline as
// report_leakage_test and secret_leakage_test.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Values seeded into a result the way a leak would put them there.
const Map<String, String> seeds = {
  'mobile number': '9876543210',
  'PIN': 'SEEDED_PIN_9f2a41c8',
  'access token': 'SEEDED_ACCESS_TOKEN_8a17fc',
  'session cookie': 'MOCK_SESSION_SECRET',
};

AuthSetupResult _succeeded() => AuthSetupResult(
      outcome: AuthSetupOutcome.succeeded,
      route: '/home',
      routeHistory: const ['/', '/home'],
      loginPerformed: false,
      elementVerified: true,
      durationMs: 41200,
      secretsUsed: [
        SecretRef.parse('env:MYTEST_AUTH_MOBILE', source: 't'),
        SecretRef.parse('env:MYTEST_AUTH_PIN', source: 't'),
      ],
      appId: 'com.example.testapp.alpha',
      appVersion: '1.0.6',
      buildMode: 'debug',
      deviceModel: 'SM-M127G',
    );

/// A failure whose every free-text field is filled in - what the result
/// carries on the unhappy path, and therefore where a message that
/// interpolated a `String` instead of a `Secret` would show up.
AuthSetupResult _polluted() => AuthSetupResult(
      outcome: AuthSetupOutcome.failed,
      failure: AuthSetupFailure.invalidCredential,
      detail: 'rejected',
      remedy: 'check the credential',
      route: '/secure-login',
      routeHistory: const ['/', '/onboarding', '/login', '/secure-login'],
      loginPerformed: true,
      elementVerified: false,
      durationMs: 38100,
      secretsUsed: [SecretRef.parse('env:MYTEST_AUTH_PIN', source: 't')],
      appId: 'com.example.testapp.alpha',
      appVersion: '1.0.6',
      buildMode: 'debug',
      deviceModel: 'SM-M127G',
    );

void main() {
  group('the serialised result', () {
    test('carries only the keys the allow-list names', () {
      // An allow-list, because a deny-list only ever catches the secrets
      // somebody remembered.
      expect(
        _succeeded().toJson().keys.toSet(),
        {
          'outcome',
          'route',
          'routeHistory',
          'loginPerformed',
          'elementVerified',
          'durationMs',
          'secretsUsed',
          'appId',
          'appVersion',
          'buildMode',
          'deviceModel',
        },
      );
    });

    test(
        'a failure adds its classification, detail and remedy - and '
        'nothing else', () {
      expect(
        _polluted().toJson().keys.toSet().difference(
              _succeeded().toJson().keys.toSet(),
            ),
        {'classification', 'detail', 'remedy'},
      );
    });

    test('records references, never values', () {
      final json = _succeeded().toJson();
      expect(
        json['secretsUsed'],
        ['env:MYTEST_AUTH_MOBILE', 'env:MYTEST_AUTH_PIN'],
      );
    });

    test('no seeded secret reaches it', () {
      for (final result in [_succeeded(), _polluted()]) {
        final text = jsonEncode(result.toJson());
        for (final entry in seeds.entries) {
          expect(text, isNot(contains(entry.value)), reason: entry.key);
        }
      }
    });

    test('and neither does the device serial', () {
      // The serial is an address, not an identity - as E-03 established
      // for baselines and E-04 for preflight. The model is recorded.
      final text = jsonEncode(_succeeded().toJson());
      expect(text, isNot(contains('RZ8T11QETWM')));
      expect(text, contains('SM-M127G'));
    });

    test('nothing names the storage route this platform refuses', () {
      final text = jsonEncode(_polluted().toJson()).toLowerCase();
      for (final forbidden in const [
        'is_logged_in',
        'sharedpreferences',
        'run-as',
        'token',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  group('exit codes', () {
    test('success is 0', () {
      expect(_succeeded().exitCode, 0);
      expect(_succeeded().succeeded, isTrue);
    });

    test('every failure is 2, never 1', () {
      // Auth setup makes no claim about any screen, so it is never in a
      // position to say the application is wrong.
      for (final failure in AuthSetupFailure.values) {
        final result = AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: failure,
          loginPerformed: false,
        );
        expect(result.exitCode, 2, reason: failure.wire);
      }
    });
  });

  group('classification', () {
    test('every failure carries a prerequisite class and a remedy', () {
      for (final failure in AuthSetupFailure.values) {
        expect(failure.klass, isA<PrerequisiteClass>(), reason: failure.wire);
        expect(failure.remedy, isNotEmpty, reason: failure.wire);
      }
    });

    test('wire names are stable and distinct', () {
      final wires = AuthSetupFailure.values.map((f) => f.wire).toList();
      expect(wires.toSet(), hasLength(wires.length));
      expect(wires, contains('SECRET_MISSING'));
      expect(wires, contains('AUTHENTICATED_STATE_NOT_REACHED'));
    });
  });
}
