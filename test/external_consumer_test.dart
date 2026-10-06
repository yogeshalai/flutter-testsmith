// Proves that a Flutter application outside this monorepo can add
// flutter_testsmith, resolve it, import it and initialise it — naming nothing
// internal to the platform.
//
// This is the acceptance test for finding E-01. It is deliberately built
// from the *real* packages rather than fixtures: what it resolves is what
// an external application resolves.
//
// Slower than the unit tests because it runs `flutter pub get` and
// `flutter test` in a scratch application. Run it with:
//   dart test test/external_consumer_test.dart
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:test/test.dart';

import '../scripts/local_registry.dart';
import '../scripts/package_boundaries.dart';

void main() {
  late Directory app;
  late LocalRegistry registry;
  late HttpServer server;

  setUpAll(() async {
    registry = LocalRegistry([
      for (final name in externallyConsumablePackages)
        PublishedPackage.fromDirectory(
          packageDirectory(name),
          gitTrackedFiles(packageDirectory(name)),
        ),
    ]);
    server = await registry.serve();

    app = Directory.systemTemp.createTempSync('external_consumer');
    File('${app.path}/pubspec.yaml').writeAsStringSync('''
name: external_consumer_probe
description: A Flutter application that is not in the platform's workspace.
publish_to: none
version: 1.0.0

environment:
  sdk: ^3.12.0

dependencies:
  flutter:
    sdk: flutter
  # The whole point: one line, a plain version constraint, no awareness
  # that flutter_testsmith_protocol exists.
  flutter_testsmith: ^0.1.0

dev_dependencies:
  flutter_test:
    sdk: flutter
''');
  });

  tearDownAll(() async {
    await server.close(force: true);
    try {
      app.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on .dart_tool briefly after pub exits.
    }
  });

  test('resolves flutter_testsmith without the application naming flutter_testsmith_protocol',
      () async {
    final result = await Process.run(
      'flutter',
      ['pub', 'get'],
      workingDirectory: app.path,
      environment: {'PUB_HOSTED_URL': registry.baseUrl},
      runInShell: true,
    );

    expect(result.exitCode, 0,
        reason: 'pub get failed:\n${result.stdout}\n${result.stderr}');

    final lock = File('${app.path}/pubspec.lock').readAsStringSync();
    expect(lock, contains('flutter_testsmith'));
    expect(lock, contains('flutter_testsmith_protocol'),
        reason: 'flutter_testsmith_protocol must arrive as a transitive dependency');
  });

  test('the consumed SDK initialises, stays disarmed, and speaks the '
      'protocol', () async {
    Directory('${app.path}/test').createSync();
    File('${app.path}/test/consumer_test.dart').writeAsStringSync('''
// Written by the platform's external_consumer_test.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  test('the SDK initialises through the package boundary', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Disabled: an application that has not opted in must not be
    // instrumented, which is the behaviour an external application relies
    // on.
    await TestSdk.initialize(
      appId: 'com.example.external_consumer_probe',
      appVersion: '1.0.0',
      config: const TestSdkConfig(enabled: false),
    );

    expect(TestSdk.isArmed, isFalse);
  });

  test('the protocol arrives transitively and is usable', () {
    // Named through flutter_testsmith's own export surface, never by depending on
    // flutter_testsmith_protocol directly.
    expect(ProtocolVersion.current.value, isNotEmpty);
    const context = AppContext(
      appVersion: '1.0.0',
      buildMode: BuildMode.debug,
      environment: 'probe',
      platform: 'android',
      devicePixelRatio: 2.0,
    );
    expect(context.platform, 'android');
  });
}
''');

    final result = await Process.run(
      'flutter',
      ['test', '--reporter', 'expanded'],
      workingDirectory: app.path,
      environment: {'PUB_HOSTED_URL': registry.baseUrl},
      runInShell: true,
    );

    expect(result.exitCode, 0,
        reason: 'flutter test failed:\n${result.stdout}\n${result.stderr}');
  });

  test('redaction behaves identically when the SDK is consumed externally',
      () async {
    // Criterion E. Masking is the one behaviour where "it probably still
    // works" is not good enough: the SDK captures live network traffic
    // from an application that may be handling real credentials, and a
    // packaging change is exactly the kind of thing that could silently
    // ship a different default policy.
    File('${app.path}/test/security_test.dart').writeAsStringSync(r"""
// Written by the platform's external_consumer_test.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  const policy = RedactionPolicy.strictDefaults();

  test('passwords, OTPs, cards, CVVs and tokens are masked', () {
    final redacted = policy.redactJson(<String, Object?>{
      'password': 'hunter2',
      'otp': '481920',
      'cardNumber': '4111111111111111',
      'cvv': '123',
      'accessToken': 'eyJhbGciOiJIUzI1NiJ9.payload.signature',
      'refresh_token': 'r3fr3sh',
      'username': 'ada',
    });

    expect(redacted['password'], RedactionPolicy.marker);
    expect(redacted['otp'], RedactionPolicy.marker);
    expect(redacted['cardNumber'], RedactionPolicy.marker);
    expect(redacted['cvv'], RedactionPolicy.marker);
    expect(redacted['accessToken'], RedactionPolicy.marker);
    expect(redacted['refresh_token'], RedactionPolicy.marker);

    // Non-sensitive fields must survive, or the capture is useless.
    expect(redacted['username'], 'ada');
  });

  test('nested credentials are masked too', () {
    final redacted = policy.redactJson(<String, Object?>{
      'user': <String, Object?>{
        'profile': <String, Object?>{'password': 'hunter2', 'name': 'ada'},
      },
      'items': <Object?>[
        <String, Object?>{'cvv': '999'},
      ],
    });

    final user = redacted['user']! as Map<String, Object?>;
    final profile = user['profile']! as Map<String, Object?>;
    expect(profile['password'], RedactionPolicy.marker);
    expect(profile['name'], 'ada');

    final items = redacted['items']! as List<Object?>;
    expect((items.first! as Map<String, Object?>)['cvv'],
        RedactionPolicy.marker);
  });

  test('the Authorization header keeps its name and loses its value', () {
    final headers = policy.redactHeaders(<String, String>{
      'Authorization': 'Bearer abc.def.ghi',
      'Content-Type': 'application/json',
    });

    expect(headers['Authorization'], RedactionPolicy.marker);
    expect(headers['Content-Type'], 'application/json');
  });

  test('an unparseable body carrying a credential is dropped wholesale', () {
    final body = policy.redactBodyString('password=hunter2&grant=x');
    expect(body, contains(RedactionPolicy.marker));
    expect(body, isNot(contains('hunter2')));
  });
}
""");

    final result = await Process.run(
      'flutter',
      ['test', 'test/security_test.dart', '--reporter', 'expanded'],
      workingDirectory: app.path,
      environment: {'PUB_HOSTED_URL': registry.baseUrl},
      runInShell: true,
    );

    expect(result.exitCode, 0,
        reason: 'redaction changed across the package boundary:\n'
            '${result.stdout}\n${result.stderr}');
  });
}
