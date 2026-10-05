// RUN-AI-CONFIG: `run --ai` and an ai.yaml it cannot use.
//
// `run` read ai.yaml in `_analyse`, after the run, with
// `readAsStringSync` and a guard for `FormatException` only. A file that
// will not decode - UTF-16, which Notepad's "Unicode" and PowerShell's
// `>` write - raises `FileSystemException` instead, which nothing there
// caught: the build, the launch and every step, then exit 255 with a
// stack trace, ahead of `_writeReports`, so no report either. The
// invariant is that a model being unavailable can never fail a run, and
// a configuration it could not read did more than fail it.
//
// `generate` reads the same file and already answers that case (its
// own guard, GENERATE-DECODE): two commands, two rules for one file.
// Now both read it through `loadAiConfig`, and `run` reads it with the
// rest of its configuration, before the device - where a problem with it
// is said once, plainly, and the run goes on without an analysis. It is
// not refused: AI is advisory, and a broken ai.yaml is not a reason to
// measure nothing.
//
// The crash itself sits behind a finished device run and is not
// reproduced here. What is driven, offline, is where the file is read.
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';

late Directory _root;
late Directory _app;

void _write(String relative, String contents) {
  File('${_app.path}/$relative')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

/// [text] as UTF-16 LE with a byte-order mark, which `readAsString`
/// refuses outright.
List<int> _utf16leWithBom(String text) => [
      0xFF,
      0xFE,
      for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
    ];

const String _flow = 'appId: com.example.x\nflow: home\nsteps:\n'
    '  - launchApp\n'
    '  - expectScreen:\n      id: /home\n';

typedef Run = ({String stdout, String stderr, int code});

Future<Run> _run({required bool ai, List<String> extra = const []}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      '${Directory.current.path}/bin/testsmith.dart',
      'run',
      '${_app.path}/flow.yaml',
      '--app',
      _app.path,
      if (ai) '--ai',
      ...extra,
    ],
    environment: {
      'PATH': File(Platform.resolvedExecutable).parent.path,
      'MYTEST_ADB': '',
      'ANDROID_HOME': '',
      'ANDROID_SDK_ROOT': '',
    },
    workingDirectory: _root.path,
  );
  return (
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    code: result.exitCode,
  );
}

/// The line about ai.yaml comes before the device gate, so it was read
/// before anything was looked for.
void _expectSaidBeforeTheDevice(Run run, String detail) {
  final both = '${run.stdout}${run.stderr}';
  expect(both, isNot(contains('Unhandled exception')), reason: both);
  expect(run.code, 2, reason: both);

  final notice = run.stdout.indexOf('no AI analysis');
  final gate = run.stdout.indexOf('adb could not be found');
  expect(notice, isNonNegative, reason: both);
  expect(gate, greaterThan(notice), reason: both);
  expect(run.stdout, contains('ai.yaml'), reason: both);
  expect(run.stdout, contains(detail), reason: both);
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('run_ai_config');
    addTearDown(() => _root.deleteSync(recursive: true));
    _app = Directory('${_root.path}/app')..createSync();
    _write('pubspec.yaml', 'name: app\n');
    _write('flow.yaml', _flow);
  });

  test('an ai.yaml that will not decode is said before the device',
      () async {
    File('${_app.path}/ai.yaml').writeAsBytesSync(
      _utf16leWithBom('apiKeyEnv: MYTEST_FIXTURE_ABSENT_KEY\n'),
    );

    _expectSaidBeforeTheDevice(await _run(ai: true), 'ai.yaml');
  });

  test('an ai.yaml that will not parse is said before the device', () async {
    _write('ai.yaml', 'apiKeyEnv: [unclosed\n');

    _expectSaidBeforeTheDevice(await _run(ai: true), 'invalid YAML');
  });

  test('control: a usable ai.yaml says nothing and reaches the device',
      () async {
    _write('ai.yaml', 'apiKeyEnv: MYTEST_FIXTURE_ABSENT_KEY\n');

    final run = await _run(ai: true);

    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, isNot(contains('no AI analysis')), reason: run.stdout);
    expect(run.stdout, contains('adb could not be found'), reason: run.stdout);
  });

  test('an unknown --ai-provider is said as the flag, not as ai.yaml',
      () async {
    // No ai.yaml at all: the mistake is on the command line, and a
    // sentence blaming a file that is not there would send someone to
    // look for it.
    final run = await _run(ai: true, extra: ['--ai-provider', 'nope']);

    expect(run.code, 2, reason: run.stdout);
    final notice = run.stdout.indexOf('no AI analysis');
    expect(notice, isNonNegative, reason: run.stdout);
    expect(run.stdout.indexOf('adb could not be found'), greaterThan(notice),
        reason: run.stdout);
    expect(run.stdout, contains('unknown AI provider "nope"'),
        reason: run.stdout);
    expect(run.stdout, isNot(contains('ai.yaml')), reason: run.stdout);
  });

  test('control: a known --ai-provider over ai.yaml says nothing', () async {
    _write('ai.yaml', 'apiKeyEnv: MYTEST_FIXTURE_ABSENT_KEY\n');

    final run = await _run(
      ai: true,
      extra: ['--ai-provider', 'groq', '--ai-model', 'some-model'],
    );

    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, isNot(contains('no AI analysis')), reason: run.stdout);
    expect(run.stdout, contains('adb could not be found'), reason: run.stdout);
  });

  test('control: without --ai, ai.yaml is not read at all', () async {
    _write('ai.yaml', 'apiKeyEnv: [unclosed\n');

    final run = await _run(ai: false);

    expect(run.code, 2, reason: run.stdout);
    expect(run.stdout, isNot(contains('ai.yaml')), reason: run.stdout);
    expect(run.stdout, contains('adb could not be found'), reason: run.stdout);
  });
}
