import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// The suite format: an ordered list of flows and what to do between
/// them.
///
/// Deliberately not a discovery mechanism. A suite is a list somebody
/// wrote, in the order they wrote it, because a suite that discovers its
/// own contents changes what it tests when a file is added and nobody
/// notices.
const String _yaml = '''
suite: ecommerce-regression

app:
  path: .
  target: lib/main_mytest.dart
  flavor: example

device:
  profile: samsung-m127g

mockApi:
  port: 8080

onFailure: continue

tests:
  - id: login
    flow: mytest/tests/login.yaml
    reset: clearState
    grant:
      - android.permission.POST_NOTIFICATIONS
  - id: home
    flow: mytest/tests/home.yaml
  - id: journey
    flow: mytest/tests/journey.yaml
    optional: true
''';

SuiteFile parse(String yaml) => SuiteFile.parse(yaml, source: 'suite.yaml');

void main() {
  group('parsing', () {
    test('reads the suite, app and device', () {
      final suite = parse(_yaml);

      expect(suite.name, 'ecommerce-regression');
      expect(suite.app.target, 'lib/main_mytest.dart');
      expect(suite.app.flavor, 'example');
      expect(suite.deviceProfile, 'samsung-m127g');
      expect(suite.mockApiPort, 8080);
    });

    test('keeps the declared order', () {
      // The order is the test. A suite that reorders itself is a
      // different suite on every run.
      expect(
        parse(_yaml).tests.map((t) => t.id),
        ['login', 'home', 'journey'],
      );
    });

    test('reads per-test configuration', () {
      final login = parse(_yaml).tests.first;

      expect(login.flow, 'mytest/tests/login.yaml');
      expect(login.reset, StateReset.clearState);
      expect(login.grant, ['android.permission.POST_NOTIFICATIONS']);
      expect(login.optional, isFalse);
    });

    test('defaults a test to required, with no reset', () {
      final home = parse(_yaml).tests[1];

      expect(home.reset, StateReset.none);
      expect(home.optional, isFalse);
      expect(home.grant, isEmpty);
    });

    test('reads optional', () {
      expect(parse(_yaml).tests[2].optional, isTrue);
    });
  });

  group('failure policy', () {
    test('continue keeps going after a failure', () {
      expect(parse(_yaml).onFailure, OnFailure.carryOn);
    });

    test('stop is fail-fast', () {
      expect(
        parse(_yaml.replaceAll('onFailure: continue', 'onFailure: stop'))
            .onFailure,
        OnFailure.stop,
      );
    });

    test('defaults to continue, so one failure does not hide the rest', () {
      const minimal = '''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''';
      expect(parse(minimal).onFailure, OnFailure.carryOn);
    });

    test('rejects an unknown policy', () {
      expect(
        () => parse(_yaml.replaceAll('onFailure: continue', 'onFailure: maybe')),
        throwsA(isA<SuiteFormatException>()),
      );
    });
  });

  group('rejections', () {
    void rejects(String yaml, Matcher message) {
      expect(
        () => parse(yaml),
        throwsA(
          isA<SuiteFormatException>()
              .having((e) => e.toString(), 'message', message),
        ),
      );
    }

    test('a duplicate test id', () {
      // Ids name results in a report and paths on disk. Two tests
      // sharing one would overwrite each other's output and make the
      // aggregate ambiguous.
      rejects('''
suite: s
device: {profile: p}
tests:
  - {id: home, flow: a.yaml}
  - {id: home, flow: b.yaml}
''', contains('home'));
    });

    test('a test with no id', () {
      rejects('''
suite: s
device: {profile: p}
tests:
  - {flow: a.yaml}
''', contains('id'));
    });

    test('a test with no flow', () {
      rejects('''
suite: s
device: {profile: p}
tests:
  - {id: a}
''', contains('flow'));
    });

    test('no tests at all', () {
      rejects('''
suite: s
device: {profile: p}
tests: []
''', contains('at least one'));
    });

    test('no device profile', () {
      rejects('''
suite: s
tests:
  - {id: a, flow: a.yaml}
''', contains('profile'));
    });

    test('an unknown top-level key', () {
      rejects('''
suite: s
device: {profile: p}
parallel: true
tests:
  - {id: a, flow: a.yaml}
''', contains('parallel'));
    });

    test('an unknown per-test key', () {
      rejects('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml, retries: 3}
''', contains('retries'));
    });

    test('an unknown reset mode', () {
      rejects('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml, reset: reinstall}
''', contains('reinstall'));
    });
  });

  group('referenced files', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('suite');
      addTearDown(() => root.deleteSync(recursive: true));
    });

    test('reports a flow that is not there', () {
      final problems = parse('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: missing.yaml}
''').missingFlows(root);

      expect(problems, hasLength(1));
      expect(problems.single, contains('missing.yaml'));
    });

    test('is happy when every flow exists', () {
      File('${root.path}/a.yaml').writeAsStringSync('x');

      final problems = parse('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''').missingFlows(root);

      expect(problems, isEmpty);
    });
  });

  group('device permissions', () {
    test('parses the permissions a suite declares for the whole run', () {
      final suite = parse('''
suite: s
device:
  profile: p
  permissions:
    - android.permission.ACCESS_FINE_LOCATION
    - android.permission.ACCESS_COARSE_LOCATION
tests:
  - {id: a, flow: a.yaml}
''');

      expect(suite.devicePermissions, [
        'android.permission.ACCESS_FINE_LOCATION',
        'android.permission.ACCESS_COARSE_LOCATION',
      ]);
    });

    test('rejects permissions that is not a list', () {
      expect(
        () => parse('''
suite: s
device:
  profile: p
  permissions: android.permission.CAMERA
tests:
  - {id: a, flow: a.yaml}
'''),
        throwsA(isA<SuiteFormatException>()),
      );
    });

    test('still rejects an unknown key under device', () {
      expect(
        () => parse('''
suite: s
device:
  profile: p
  permission: android.permission.CAMERA
tests:
  - {id: a, flow: a.yaml}
'''),
        throwsA(isA<SuiteFormatException>()),
      );
    });
  });

  group('preconditions', () {
    test('parses a named precondition and the routes that contradict it', () {
      final suite = parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated:
    description: a session obtained through the real login flow
    unmetOn: [/login, /onboarding]
    remedy: Sign in on the device through the real application UI.
tests:
  - {id: a, flow: a.yaml, requires: [authenticated]}
''');

      final precondition = suite.preconditions['authenticated']!;
      expect(precondition.name, 'authenticated');
      expect(
        precondition.description,
        'a session obtained through the real login flow',
      );
      expect(precondition.unmetOn, ['/login', '/onboarding']);
      expect(precondition.remedy, contains('Sign in'));
      expect(suite.tests.single.requires, ['authenticated']);
    });

    test('rejects a requires naming no declared precondition', () {
      expect(
        () => parse('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml, requires: [authenticated]}
'''),
        throwsA(
          isA<SuiteFormatException>().having(
            (e) => e.message,
            'message',
            contains('no precondition'),
          ),
        ),
      );
    });

    test('rejects a precondition with no unmetOn, which could never be checked',
        () {
      expect(
        () => parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated:
    description: a session
tests:
  - {id: a, flow: a.yaml}
'''),
        throwsA(
          isA<SuiteFormatException>()
              .having((e) => e.message, 'message', contains('unmetOn')),
        ),
      );
    });

    test('rejects an empty unmetOn for the same reason', () {
      expect(
        () => parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated: {unmetOn: []}
tests:
  - {id: a, flow: a.yaml}
'''),
        throwsA(isA<SuiteFormatException>()),
      );
    });

    test('rejects an unknown key inside a precondition', () {
      expect(
        () => parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated:
    unmetOn: [/login]
    remdy: typo
tests:
  - {id: a, flow: a.yaml}
'''),
        throwsA(isA<SuiteFormatException>()),
      );
    });

    test('rejects a requires that is not a list', () {
      expect(
        () => parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated: {unmetOn: [/login]}
tests:
  - {id: a, flow: a.yaml, requires: authenticated}
'''),
        throwsA(isA<SuiteFormatException>()),
      );
    });

    test('names every test that requires a precondition, in declared order',
        () {
      final suite = parse('''
suite: s
device: {profile: p}
preconditions:
  authenticated: {unmetOn: [/login]}
tests:
  - {id: a, flow: a.yaml, requires: [authenticated]}
  - {id: b, flow: b.yaml}
  - {id: c, flow: c.yaml, requires: [authenticated]}
''');

      expect(suite.testsRequiring('authenticated'), ['a', 'c']);
      expect(suite.testsRequiring('nothing-by-that-name'), isEmpty);
    });
  });

  group('an E-03 suite is unchanged by any of this', () {
    test('every new key defaults to empty', () {
      final suite = parse('''
suite: s
device: {profile: p}
tests:
  - {id: a, flow: a.yaml}
''');

      expect(suite.devicePermissions, isEmpty);
      expect(suite.preconditions, isEmpty);
      expect(suite.tests.single.requires, isEmpty);
    });
  });
}
