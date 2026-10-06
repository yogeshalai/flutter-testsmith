// Which adb `testsmith` actually runs, driven through the real executable
// with a controlled environment.
//
// The policy itself is unit-tested in the engine's suite; these prove it
// reaches the process. Before this, every command ran the bare name `adb` and let
// the operating system pick - so on a machine with an old standalone
// platform-tools on PATH and the Android Studio SDK in ANDROID_HOME, the
// tool used the old one and never said so.
//
// `testsmith doctor` is the subject because it is the one command that
// reports what it found rather than only using it, and because it needs
// no device.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

/// A file that exists and is named like an adb for this platform.
String _fakeAdb(String directory) {
  final name = Platform.isWindows ? 'adb.exe' : 'adb';
  final file = File('${_root.path}/$directory/$name')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('not really adb');
  return file.path;
}

/// Runs `testsmith doctor` with [environment] layered over this process's.
///
/// Layered rather than replacing: dart still needs its own PATH to run at
/// all, and an empty string reads as unset, which is how a variable is
/// cleared for one run.
Future<String> _doctor(Map<String, String> environment) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', 'doctor'],
    environment: environment,
  );
  return '${result.stdout}';
}

/// The one `adb` line out of the report.
String _adbLine(String report) => report
    .split('\n')
    .firstWhere((line) => line.contains(' adb '), orElse: () => '');

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('adb_discovery');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('an SDK in ANDROID_HOME is preferred over whatever is on PATH',
      () async {
    // The defect, end to end. The fake is not a working adb, so the
    // version check fails - and that failure is the proof: it could only
    // have come from the SDK copy, because the real adb on this machine's
    // PATH would have answered.
    final sdk = '${_root.path}/sdk';
    _fakeAdb('sdk/platform-tools');

    final line = _adbLine(await _doctor({'ANDROID_HOME': sdk}));

    expect(line, contains('platform-tools'));
    expect(line, contains(_root.path));
  });

  test('MYTEST_ADB outranks ANDROID_HOME', () async {
    _fakeAdb('sdk/platform-tools');
    final explicit = _fakeAdb('elsewhere');

    final line = _adbLine(await _doctor({
      'ANDROID_HOME': '${_root.path}/sdk',
      'MYTEST_ADB': explicit,
    }));

    expect(line, contains('elsewhere'));
    expect(line, isNot(contains('platform-tools')));
  });

  test('an explicit adb that is not there is named, and not replaced',
      () async {
    // Falling back to a working PATH adb here would be the silent
    // wrongness: the run would succeed against a binary nobody chose.
    final report = await _doctor({'MYTEST_ADB': '${_root.path}/nope/adb'});

    expect(report, contains('MYTEST_ADB names an adb that is not there'));
    expect(report, contains('nope'));
    // The negative control: it must not have quietly used PATH instead.
    expect(_adbLine(report), isNot(contains('Android Debug Bridge')));
  });

  test('a stale ANDROID_HOME is reported, and does not stop the run',
      () async {
    // Non-regression. A machine whose PATH adb works must keep working;
    // the misconfiguration is said out loud rather than being fatal.
    final report = await _doctor({'ANDROID_HOME': '${_root.path}/gone'});
    final line = _adbLine(report);

    expect(line, contains('PATH:'));
    expect(line, contains('has no platform-tools'));
  });

  test('with nothing configured it falls back to PATH, as it always did',
      () async {
    final line = _adbLine(await _doctor({
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
      'MYTEST_ADB': '',
    }));

    expect(line, contains('PATH:'));
    expect(line, contains('Android Debug Bridge'));
  });

  test('the report names which adb answered, not merely that one did',
      () async {
    // "adb: ok" alone cannot tell you which of two installed copies ran,
    // and the two do not share a server.
    final line = _adbLine(await _doctor(const {}));

    expect(line, matches(RegExp(r'\((ANDROID_HOME|ANDROID_SDK_ROOT|PATH|MYTEST_ADB): ')));
  });
}
