// Which Android package `testsmith smoke` and `testsmith inspect` target, and
// what happens when nobody said.
//
// Both used to default to `com.example.ecommerce_app` - this repository's
// own example. Pointed at anybody else's application the run drove the
// right app and then force-stopped a package that was not installed.
// Android reports that as success, so the tool believed it had torn down,
// the real application stayed running, and the *next* run inherited it.
// That is E-03, and the default was left in place when E-03 was fixed by
// adding the flag.
//
// The identity is required rather than derived, and the reasoning is in
// `requiredAppId`: the installed package is the applicationId of the
// variant that was built, which a flavour or an applicationIdSuffix
// changes, so reading `build.gradle` would be right for simple projects
// and quietly wrong for flavoured ones - the same quiet wrongness.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/adb_device_environment.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import 'support/no_device_adb.dart';

/// An Android that behaves the way Android actually behaves.
///
/// `am force-stop` exits 0 whatever it is handed - that is the whole
/// hazard - while `pm list packages` reports only what is there.
class _FakeAndroid implements ProcessRunner {
  _FakeAndroid(this.installed);

  final Set<String> installed;
  final List<String> commands = [];

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) {
    commands.add('$executable ${arguments.join(' ')}');

    if (arguments.join(' ').contains('pm list packages')) {
      // `pm list packages <id>` matches on prefix, which is why the
      // production probe compares whole lines.
      final query = arguments.last.split(' ').last;
      return Future.value(ProcessResultData(
        exitCode: 0,
        stdout: [
          for (final id in installed)
            if (id.startsWith(query)) 'package:$id',
        ].join('\n'),
        stderr: '',
      ));
    }

    return Future.value(
      const ProcessResultData(exitCode: 0, stdout: '', stderr: ''),
    );
  }
}

late Directory _root;

/// An ordinary Flutter project that is not this repository's example.
String _project() {
  final directory = Directory('${_root.path}/myapp')..createSync();
  File('${directory.path}/pubspec.yaml').writeAsStringSync('name: myapp\n');
  return directory.path;
}

Future<ProcessResult> _mytest(List<String> arguments, {required String from}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
      workingDirectory: from,
      // "On a machine with no usable device" is arranged, not assumed.
      environment: noDeviceEnvironment(_root),
    );

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('app_identity');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  group('the E-03 semantic, at the command boundary', () {
    test('force-stopping a package that is not installed succeeds', () async {
      // The fact everything else here exists because of. Nothing in the
      // result distinguishes this from a teardown that worked.
      final android = _FakeAndroid({'com.acme.myapp'});
      final device = AdbDeviceController(
        serial: 'SERIAL',
        processRunner: android,
      );

      await expectLater(
        device.terminateApp('com.example.ecommerce_app'),
        completes,
      );
      expect(
        android.commands.single,
        contains('am force-stop com.example.ecommerce_app'),
      );
    });

    test('and the real application is never asked to stop', () async {
      final android = _FakeAndroid({'com.acme.myapp'});
      final device = AdbDeviceController(
        serial: 'SERIAL',
        processRunner: android,
      );

      await device.terminateApp('com.example.ecommerce_app');

      expect(
        android.commands.where((c) => c.contains('com.acme.myapp')),
        isEmpty,
        reason: 'the application that was actually running stayed running',
      );
    });

    test('while the device could say so all along', () async {
      // The information the guard rests on. It was always available; it
      // was simply never asked for before a package was addressed.
      final android = _FakeAndroid({'com.acme.myapp'});
      final environment = AdbDeviceEnvironment(
        serial: 'SERIAL',
        processRunner: android,
      );

      expect(await environment.isInstalled('com.example.ecommerce_app'),
          isFalse);
      expect(await environment.isInstalled('com.acme.myapp'), isTrue);
    });

    test('and a flavoured sibling does not answer for it', () async {
      // `pm list packages com.acme.myapp` also lists
      // `com.acme.myapp.debug`. A prefix match would call the base id
      // installed when only the flavoured build is - which is the exact
      // shape that makes deriving the id from build.gradle unsafe.
      final android = _FakeAndroid({'com.acme.myapp.debug'});
      final environment = AdbDeviceEnvironment(
        serial: 'SERIAL',
        processRunner: android,
      );

      expect(await environment.isInstalled('com.acme.myapp'), isFalse);
      expect(await environment.isInstalled('com.acme.myapp.debug'), isTrue);
    });
  });

  group('testsmith smoke', () {
    test('will not run without --app-id', () async {
      final result = await _mytest(const ['smoke'], from: _project());

      expect(result.exitCode, 1);
      expect(result.stdout, contains('--app-id is required'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('offers no package as a default', () async {
      // Asserted on --help rather than on a run, because a run with no
      // device never gets far enough to print the id it would have used.
      // The old help said: (defaults to "com.example.ecommerce_app").
      final result = await _mytest(const ['smoke', '--help'], from: _project());

      expect(result.stdout, contains('--app-id'));
      expect(result.stdout, isNot(contains('com.example.ecommerce_app')));
      expect(result.stdout, isNot(contains('defaults to "com.')));
    });

    test('says how to find the right one', () async {
      final result = await _mytest(const ['smoke'], from: _project());

      expect(result.stdout, contains('pm list packages'));
      expect(result.stdout, contains('applicationIdSuffix'));
    });

    test('asks for it before it touches a device', () async {
      // Eight minutes into a build is not where a missing flag should
      // surface. The identity check runs before device selection, so the
      // message is about the flag and not about a handset.
      final result = await _mytest(const ['smoke'], from: _project());

      expect(result.stdout, isNot(contains('No usable device')));
    });

    test('accepts one that was given, and moves on', () async {
      // The negative control for the checks above: with an id present the
      // run proceeds past identity and stops at whatever is next, which
      // on a machine with no usable device is the device.
      final result = await _mytest(
        const ['smoke', '--app-id', 'com.acme.myapp'],
        from: _project(),
      );

      expect(result.stdout, isNot(contains('--app-id is required')));
      // And stops at the device gate - never on a real handset, if one is
      // attached to the machine running this.
      expect(result.stdout, contains('No usable device attached'),
          reason: '${result.stdout}');
    });
  });

  group('testsmith inspect', () {
    test('will not run without --app-id', () async {
      final result = await _mytest(const ['inspect'], from: _project());

      expect(result.exitCode, 1);
      expect(result.stdout, contains('--app-id is required'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('offers no package as a default', () async {
      final result =
          await _mytest(const ['inspect', '--help'], from: _project());

      expect(result.stdout, contains('--app-id'));
      expect(result.stdout, isNot(contains('com.example.ecommerce_app')));
      expect(result.stdout, isNot(contains('defaults to "com.')));
    });

    test('accepts one that was given, and moves on', () async {
      final result = await _mytest(
        const ['inspect', '--app-id', 'com.acme.myapp'],
        from: _project(),
      );

      expect(result.stdout, isNot(contains('--app-id is required')));
      expect(result.stdout, contains('No usable device attached'),
          reason: '${result.stdout}');
    });
  });

  test('smoke and inspect answer the identity question identically',
      () async {
    // Two commands that launched and force-stopped applications under
    // different rules would be two answers to one question. Before this
    // they already differed in what they told you: `smoke` explained the
    // hazard and `inspect` said "Package id, used to stop the app
    // afterwards."
    final project = _project();
    final smoke = await _mytest(const ['smoke'], from: project);
    final inspect = await _mytest(const ['inspect'], from: project);

    expect(smoke.exitCode, inspect.exitCode);
    expect(smoke.stdout, inspect.stdout);
    // Not vacuous: both must actually be the identity refusal, and not
    // two commands agreeing that no device is attached.
    expect(smoke.stdout, contains('--app-id is required'));
  });
}
