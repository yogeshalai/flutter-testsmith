// The files `testsmith run` and `testsmith suite run` write for a run,
// with the 1.5 network record in them.
//
// `writeRunReports` is the one writer both commands share. These check
// what reaches disk: the record in `result.json`, the same record on the
// page beside it, and nothing on the page that needs a network to load.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith/src/cli/project_config.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:test/test.dart';

RunResult _run(NetworkRecord network) => RunResult(
      flowName: 'browse',
      appId: 'com.example.shop',
      device: 'pixel-7',
      startedAt: DateTime.utc(2026, 10, 2, 9),
      duration: const Duration(seconds: 3),
      steps: const [
        StepOutcome(
          description: 'tap "home.open_product"',
          kind: StepKind.tap,
          status: StepStatus.ok,
          durationMs: 40,
          startedOffsetMs: 1500,
        ),
      ],
      screens: const [],
      sessionId: 'session-1',
      network: network,
    );

final _captured = NetworkRecord(
  state: NetworkCaptureState.active,
  durationClock: NetworkDurationClock.monotonic,
  exchanges: [
    NetworkExchange(
      requestId: 'r1',
      method: 'GET',
      url: 'http://api/products?access_token=[REDACTED]',
      screenId: '/home',
      requestedAt: DateTime.utc(2026, 10, 2, 9, 0, 1),
      respondedAt: DateTime.utc(2026, 10, 2, 9, 0, 1, 90),
      statusCode: 200,
      durationMs: 90,
      outcome: ExchangeOutcome.success,
    ),
  ],
);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('run_report_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('result.json and report.html carry the same network record', () async {
    final written = await writeRunReports(_run(_captured), temp);

    expect(written.json.path, '${temp.path}/result.json');
    expect(written.html.path, '${temp.path}/report.html');

    final json = jsonDecode(written.json.readAsStringSync()) as Map;
    final network = json['network'] as Map;
    expect(json['resultSchemaVersion'], '1.6');
    expect(json['sessionId'], 'session-1');
    expect(network['capture'], 'active');
    expect(network['durationClock'], 'monotonic');
    expect(((network['exchanges'] as List).single as Map)['durationMs'], 90);

    final html = written.html.readAsStringSync();
    // Every request in the file is on the page, and the page names no
    // request the file does not hold: one row per exchange.
    for (final raw in network['exchanges'] as List) {
      expect(html, contains((raw as Map)['url'] as String));
    }
    final apiTable = html.substring(html.indexOf('<h2>API calls</h2>'),
        html.indexOf('</section>', html.indexOf('<h2>API calls</h2>')));
    expect('<tr data-k='.allMatches(apiTable),
        hasLength((network['exchanges'] as List).length));
    expect(html, contains('<h2>API calls</h2>'));
    expect(html, contains('http://api/products?access_token=[REDACTED]'));
    expect(html, contains('90ms'));
    expect(html, contains('Took (monotonic)'));
    expect(html, contains('<h2>Timeline</h2>'));
  });

  test('a project with no capture still gets both files, saying so',
      () async {
    // The application under test links no supported client, or turned
    // capture off. That is a property of the run to state, not a reason
    // to write less.
    final written = await writeRunReports(
      _run(const NetworkRecord(
        state: NetworkCaptureState.unavailable,
        exchanges: [],
        reasons: ['the application did not offer network capture'],
      )),
      temp,
    );

    final json = jsonDecode(written.json.readAsStringSync()) as Map;
    expect((json['network'] as Map)['capture'], 'unavailable');
    expect(written.html.readAsStringSync(),
        contains('not evidence that none was made'));
  });

  test('the page needs nothing but itself', () async {
    final written = await writeRunReports(_run(_captured), temp);
    final html = written.html.readAsStringSync();

    expect(html, isNot(contains('<link')));
    expect(html, isNot(contains(' src=')));
    expect(html, contains("default-src 'none'"));
  });

  test('a directory that cannot be written is a FileSystemException', () {
    // `run` turns this into a message and exit 2 (run_command
    // `_writeReports`); the writer itself must not swallow it.
    final blocker = File('${temp.path}/taken')..writeAsStringSync('');

    expect(
      writeRunReports(_run(_captured), Directory(blocker.path)),
      throwsA(isA<FileSystemException>()),
    );
  });
}
