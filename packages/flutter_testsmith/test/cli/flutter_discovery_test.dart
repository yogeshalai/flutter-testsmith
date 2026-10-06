// Which flutter `testsmith` actually runs, driven through the real
// executable with a controlled PATH.
//
// The policy itself is unit-tested in the engine's suite; these
// prove it reaches the process. Before this, every command passed the
// bare name `flutter` and let the operating system pick - so `testsmith
// doctor` printed a version with nothing to say which of two SDKs on a
// machine had produced it.
//
// `testsmith doctor` is the subject because it is the one command that
// reports what it found rather than only using it, and because it needs
// no device.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

/// A file that exists, is named like a flutter for this platform, and
/// exits 3 when run.
///
/// Runnable on purpose. A fake that merely exists would prove the
/// resolver picked it; one that runs and answers proves the *process
/// layer* was handed it.
String _fakeFlutter(String directory) {
  final dir = Directory('${_root.path}/$directory')
    ..createSync(recursive: true);

  if (Platform.isWindows) {
    final file = File('${dir.path}/flutter.bat')
      ..writeAsStringSync('@echo off\r\nexit /b 3\r\n');
    return file.path;
  }
  final file = File('${dir.path}/flutter')
    ..writeAsStringSync('#!/bin/sh\nexit 3\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// Runs `testsmith doctor` with [environment] layered over this process's.
///
/// Layered rather than replacing: dart still needs its own PATH to run at
/// all. To make a directory win, it is prepended to the real PATH rather
/// than replacing it.
Future<String> _doctor(
  Map<String, String> environment, {
  String? from,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', 'doctor'],
    environment: environment,
    workingDirectory: from,
  );
  return '${result.stdout}';
}

/// A fake flutter that says which one it is, rather than only failing.
///
/// [_fakeFlutter] exits 3 and prints nothing, which is enough to show
/// that *a* fake ran. Telling two fakes apart needs each to name itself.
String _talkingFakeFlutter(String directory, String marker) {
  final dir = Directory(directory)..createSync(recursive: true);

  if (Platform.isWindows) {
    final file = File('${dir.path}/flutter.bat')
      ..writeAsStringSync('@echo off\r\necho MARKER=$marker\r\n');
    return file.path;
  }
  final file = File('${dir.path}/flutter')
    ..writeAsStringSync('#!/bin/sh\necho MARKER=$marker\n');
  Process.runSync('chmod', ['+x', file.path]);
  return file.path;
}

/// Runs the discover-then-launch pair with two different directories.
///
/// [from] is where discovery happens - the probe's own cwd. [launchInto]
/// is what `AppSession` would pass as the child's `workingDirectory`.
Future<String> _discoverThenLaunch({
  required String from,
  required String launchInto,
  required Map<String, String> environment,
}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/test/cli/support/flutter_launch_probe.dart',
      launchInto,
    ],
    environment: environment,
    workingDirectory: from,
  );
  return '${result.stdout}${result.stderr}';
}

String get _separator => Platform.isWindows ? ';' : ':';

/// PATH with [directory] in front of whatever this machine already has.
Map<String, String> _pathWith(String directory) => {
      'PATH': '$directory$_separator${Platform.environment['PATH'] ?? ''}',
    };

/// One spelling of a path, so a comparison is about the path.
///
/// The temp tree here is built with `/` and the operating system reports
/// a working directory with `\`; both name the same directory.
String _oneDialect(String path) => path.replaceAll(r'\', '/');

/// The one `Flutter` line out of the report.
String _flutterLine(String report) => report
    .split('\n')
    .firstWhere((line) => line.contains('Flutter'), orElse: () => '');

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('flutter_discovery');
    addTearDown(() => _root.deleteSync(recursive: true));
  });

  test('the report names which flutter answered, not merely that one did',
      () async {
    final line = _flutterLine(await _doctor(const {}));

    expect(line, contains('PATH:'));
    // A full path, not the bare name the tool used to pass.
    expect(line, anyOf(contains('/'), contains(r'\')));
  });

  test('the first PATH entry wins, and it is the one that is run', () async {
    // The seam, end to end. The fake is not a working flutter, so the
    // version check fails - and that failure is the proof: it could only
    // have come from the fake, because the real flutter on this machine's
    // PATH would have answered with a version.
    final fake = _fakeFlutter('first');

    final line = _flutterLine(await _doctor(_pathWith(File(fake).parent.path)));

    expect(line, contains('PATH:'));
    expect(line, contains(_root.path),
        reason: 'the resolved executable must be the one that ran');
    // The negative control: it must not have quietly used the real one.
    expect(line, isNot(contains('channel')));
  });

  test('a directory earlier on PATH outranks one later', () async {
    _fakeFlutter('second');
    final first = _fakeFlutter('first');

    final line = _flutterLine(await _doctor({
      'PATH': '${File(first).parent.path}$_separator'
          '${_root.path}/second$_separator'
          '${Platform.environment['PATH'] ?? ''}',
    }));

    expect(line, contains('first'));
    expect(line, isNot(contains('second')));
  });

  test('a flutter that will not answer is reported as located, not missing',
      () async {
    // "It is here and it does not work" and "it is not here" are
    // different sentences, and only one of them names the thing to fix.
    final fake = _fakeFlutter('broken');

    final report = await _doctor(_pathWith(File(fake).parent.path));

    expect(report, isNot(contains('was not found on PATH')));
    expect(
      _flutterLine(report),
      anyOf(contains('exited with'), contains('would not run')),
    );
  });

  test('discovery adds no new configuration surface', () async {
    // S9-A is PATH and nothing else. If an override had crept in, a
    // report produced with these set would differ from one without.
    final withVariables = _flutterLine(await _doctor(const {
      'FLUTTER_ROOT': r'/nowhere/at/all',
      'MYTEST_FLUTTER': r'/nowhere/at/all/flutter',
    }));
    final without = _flutterLine(await _doctor(const {}));

    expect(withVariables, without);
    expect(withVariables, isNot(contains('nowhere')));
  });

  // S10-A. A relative PATH entry - `tools`, or `.` - is legal, and used
  // to come back from the resolver spelled the way PATH spelled it.
  // These drive the real executable with a real relative entry, from a
  // real directory, because the whole defect is about which directory
  // the string is read from.
  group('a relative PATH entry', () {
    test('is reported as an absolute path, not as PATH spelled it',
        () async {
      final home = Directory('${_root.path}/home')..createSync();
      _talkingFakeFlutter('${home.path}/tools', 'HOME');

      final line = _oneDialect(_flutterLine(
        await _doctor(_pathWith('tools'), from: home.path),
      ));

      expect(line, contains('PATH:'));
      expect(line, contains(_oneDialect(home.path)),
          reason: 'the report must name a file, not a directory-relative '
              'fragment that means different things to different readers');
      expect(line, isNot(contains('PATH: tools/')));
    });

    test('launching from elsewhere still runs the flutter that was found',
        () async {
      // The regression, exactly. Both directories hold a `tools` with a
      // flutter in it, so there is nothing to fall back to and no error
      // to notice: before S10-A the resolver validated HOME's copy, the
      // launch re-read `tools/flutter` under the application root, and
      // APP's copy ran instead - a different SDK, silently.
      final home = Directory('${_root.path}/home')..createSync();
      final app = Directory('${_root.path}/app')..createSync();
      _talkingFakeFlutter('${home.path}/tools', 'DISCOVERED');
      _talkingFakeFlutter('${app.path}/tools', 'COLLIDING');

      final report = await _discoverThenLaunch(
        from: home.path,
        launchInto: app.path,
        environment: _pathWith('tools'),
      );

      expect(report, contains('MARKER=DISCOVERED'), reason: report);
      expect(report, isNot(contains('MARKER=COLLIDING')), reason: report);
      expect(report, contains('EXIT=0'), reason: report);
    });
  });
}
