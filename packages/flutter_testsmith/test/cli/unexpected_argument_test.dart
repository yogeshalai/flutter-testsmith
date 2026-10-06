// STRAY-ARGUMENT: `smoke` and `inspect` take no positional argument.
//
// `run` and `auth setup` each take exactly one and refuse anything else
// at 64. `smoke` and `inspect` take none, and dropped whatever they were
// given. Measured at 25fdc3b, offline:
//
//   inspect --app-id com.x login.button   -> on to the device, exit 1
//   smoke --app-id com.x --tree false     -> on to the device, exit 1
//   inspect --app-id com.x --bogus        -> usage error, exit 64
//
// The first is `--tap` forgotten: it would have captured the first
// screen rather than the one asked for, and said nothing. The second is
// a flag given a value: `--tree` is on and `false` was discarded, so the
// tree printed that was asked not to be. Both are the invocation being
// wrong, which the same commands already answer at 64 for an option they
// do not know - so the same answer, before anything else is looked at.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

Map<String, String> get _offline => {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    };

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _testsmith(List<String> arguments) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', '${Directory.current.path}/bin/testsmith.dart', ...arguments],
    environment: _offline,
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('stray_argument');
    addTearDown(() => _root.deleteSync(recursive: true));
    File('${_root.path}/pubspec.yaml').writeAsStringSync('name: app\n');
  });

  for (final command in ['inspect', 'smoke']) {
    group(command, () {
      test('a positional argument is a usage error, before the device',
          () async {
        final run = await _testsmith(
          [command, '--app-id', 'com.example.x', 'login.button'],
        );

        expect(run.code, 64);
        expect('${run.stdout}${run.stderr}', contains('login.button'));
        expect(
          '${run.stdout}${run.stderr}',
          isNot(contains('adb could not be found')),
        );
      });

      test('control: without it, the device gate is reached', () async {
        final run = await _testsmith([command, '--app-id', 'com.example.x']);

        expect(run.code, 1);
        expect(run.stdout, contains('adb could not be found'));
      });
    });
  }

  test('smoke: a value given to a flag is a usage error', () async {
    final run = await _testsmith(
      ['smoke', '--app-id', 'com.example.x', '--tree', 'false'],
    );

    expect(run.code, 64);
    expect('${run.stdout}${run.stderr}', contains('false'));
  });
}
