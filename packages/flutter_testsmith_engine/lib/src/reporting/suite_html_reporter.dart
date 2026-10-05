import 'suite_result.dart';

/// Renders a suite result as a page a person can read.
///
/// Rendered from the decoded JSON, as the run report already is: the
/// page is then a pure function of the file CI consumes, so the two
/// cannot drift apart, and it can be tested with no run required.
String renderSuiteReport(SuiteResult result) => _render(result.toJson());

String _render(Map<String, Object?> json) {
  final tests = (json['tests'] as List?) ?? const [];
  final counts = (json['counts'] as Map?) ?? const {};
  final profile = (json['deviceProfile'] as Map?) ?? const {};
  final verdict = '${json['verdict']}';

  return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${_esc(json['suite'])} - suite report</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.55 ui-sans-serif, system-ui, sans-serif;
         margin: 0; padding: 32px; max-width: 960px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .meta { opacity: .7; font-size: 13px; margin-bottom: 24px; }
  .verdict { display: inline-block; padding: 4px 12px; border-radius: 999px;
             font-weight: 600; letter-spacing: .04em; }
  .pass { background: #12603a; color: #d6ffe8; }
  .fail { background: #7a1220; color: #ffd9de; }
  .error { background: #6b2d00; color: #ffe2cc; }
  .skip { background: #33383f; color: #d8dde4; }
  table { border-collapse: collapse; width: 100%; margin: 16px 0 28px; }
  th, td { text-align: left; padding: 8px 10px;
           border-bottom: 1px solid rgba(128,128,128,.28); }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: .06em;
       opacity: .7; }
  td.v { width: 76px; }
  .reason { opacity: .75; font-size: 13px; }
  .scope { opacity: .7; font-size: 13px; margin-top: 28px; }
  h2 { font-size: 14px; text-transform: uppercase; letter-spacing: .06em;
       opacity: .7; margin: 28px 0 8px; }
  .kind { display: inline-block; padding: 1px 7px; border-radius: 4px;
          font-size: 11px; letter-spacing: .05em; }
  .product { background: #1d3557; color: #dbe7ff; }
  .environment { background: #4a3a12; color: #ffeec2; }
  .s-pass { color: #2e9e63; }
  .s-fail { color: #d2455a; }
  .s-skip { opacity: .6; }
  .s-error { color: #d98324; }
  .evidence { font-size: 12px; margin-bottom: 4px; }
  .evidence span + span::before { content: ' · '; opacity: .45; }
  .satisfied { color: #3aa06a; }
  .blocked { color: #d4485c; font-weight: 600; }
  .deferred { color: #c59a2a; }
  .notice { opacity: .75; }
  td.k { width: 128px; }
  .owner { opacity: .6; font-size: 12px; }
</style>
</head>
<body>
<h1>${_esc(json['suite'])}</h1>
<div class="meta">
  ${_esc(profile['id'])}${profile['model'] == null ? '' : ' &middot; ${_esc(profile['model'])}'}${profile['os'] == null ? '' : ' &middot; ${_esc(profile['os'])}'}
  ${json['appVersion'] == null ? '' : ' &middot; app ${_esc(json['appVersion'])}'}${json['buildMode'] == null ? '' : ' (${_esc(json['buildMode'])})'}
  <br>${_esc(json['startedAt'])} &middot; ${_duration(json['durationMs'])}
</div>

<p><span class="verdict ${_esc(verdict)}">${_esc(verdict.toUpperCase())}</span>
  &nbsp;${_esc(counts['pass'])} passed,
  ${_esc(counts['fail'])} failed,
  ${_esc(counts['error'])} errored,
  ${_esc(counts['skip'])} skipped
  &nbsp;&middot;&nbsp; exit ${_esc(json['exitCode'])}</p>

${_preflight(json['preflight'])}

<table>
  <tr><th>Test</th><th class="v">Verdict</th><th class="k">Says about</th>
      <th>Duration</th><th>Detail</th></tr>
  ${tests.map(_row).join('\n  ')}
</table>
${_cleanup(json['cleanup'])}

<p class="scope">A suite verdict is ERROR before FAIL before PASS, and a
skip outranks nothing. A required test that did not run counts as an
error, not as a pass. A row that says ENVIRONMENT is a statement about
the run rather than about the application: nothing was learned about that
screen, which is why it can never be reported as a failure.</p>
</body>
</html>
''';
}

String _row(Object? node) {
  final test = (node as Map).cast<String, Object?>();
  final verdict = '${test['verdict']}';
  final checks = (test['checks'] as Map?)?.cast<String, Object?>();
  final failures = (checks?['failures'] as List?) ?? const [];

  // Whether this row says something about the application or about the
  // run. Absent from a report written before E-04, so it falls back to
  // nothing rather than guessing "product" on its behalf.
  final kind = test['classification'];
  final classification = kind == null
      ? ''
      : '<span class="kind ${_esc(kind)}">${_esc('$kind'.toUpperCase())}</span>'
          '${test['environment'] == null ? '' : ' <span class="owner">${_esc(test['environment'])}</span>'}';

  final detail = StringBuffer();
  if (test['reason'] != null) {
    detail.write('<div class="reason">${_esc(test['reason'])}</div>');
  }

  // The structured evidence, for a row that is not a plain pass.
  //
  // Withheld from a passing row on purpose: every field below exists for
  // a passing run too, and printing them would expand every green row
  // with something nobody needs to read. A row that did not pass is the
  // one a reader has opened the page for.
  if (verdict != 'pass') {
    detail
      ..write(_dimensions(test['dimensions']))
      ..write(_screens(test['screens']));
  }

  for (final failure in failures.take(8)) {
    final map = (failure as Map).cast<String, Object?>();
    detail.write(
      '<div class="reason">${_esc(map['validator'])}'
      '${map['element'] == null ? '' : ' ${_esc(map['element'])}'}: '
      '${_esc(map['message'])}</div>',
    );
  }
  if (failures.length > 8) {
    detail.write(
      '<div class="reason">&hellip; and ${failures.length - 8} more</div>',
    );
  }

  // `checks.errors` has been in the file since the suite gained the
  // three lists and has never had a reader. It is what says *which*
  // validator could not run, where a dimension only says that one
  // could not.
  final errors = (checks?['errors'] as List?) ?? const [];
  for (final error in errors.take(8)) {
    final map = (error! as Map).cast<String, Object?>();
    detail.write(
      '<div class="reason">${_esc(map['validator'])}: '
      '${_esc(map['message'])}</div>',
    );
  }
  if (errors.length > 8) {
    detail.write(
      '<div class="reason">&hellip; and ${errors.length - 8} more</div>',
    );
  }

  return '<tr>'
      '<td>${_esc(test['id'])}'
      '${test['required'] == false ? ' <span class="reason">(optional)</span>' : ''}'
      '</td>'
      '<td class="v"><span class="verdict ${_esc(verdict)}">'
      '${_esc(verdict.toUpperCase())}</span></td>'
      '<td class="k">$classification</td>'
      '<td>${_duration(test['durationMs'])}</td>'
      '<td>$detail</td>'
      '</tr>';
}

/// Each dimension and the verdict it reached, as the run recorded them.
///
/// Read, never derived. `RunResult.overall` and the four dimension
/// verdicts are canonical and already in the file; recomputing any of
/// them here would give the page licence to disagree with the JSON
/// beside it.
///
/// All four are shown, including the ones that passed and the ones that
/// were skipped. "The API answered correctly and the UI could not be
/// read" is the sentence this exists to make available, and it needs
/// both halves.
String _dimensions(Object? node) {
  if (node is! Map || node.isEmpty) return '';

  final spans = StringBuffer();
  for (final key in const ['ui', 'api', 'figma', 'visual']) {
    final entry = (node[key] as Map?)?.cast<String, Object?>();
    if (entry == null) continue;
    final status = '${entry['status']}';
    spans.write(
      '<span class="s-${_esc(status)}">${_esc(key.toUpperCase())} '
      '${_esc(status)}</span>',
    );
  }

  return spans.isEmpty ? '' : '<div class="evidence">$spans</div>';
}

/// Each screen and the status it reached.
///
/// From `ScreenResult.status`, which is canonical. A screen that passed
/// appears here and in none of the failure, error or skip lists, which
/// is the whole reason this is rendered: a page that showed only what
/// went wrong could not say that two screens were fine and a third could
/// not be checked.
String _screens(Object? node) {
  if (node is! List || node.isEmpty) return '';

  final spans = StringBuffer();
  for (final raw in node) {
    final screen = (raw! as Map).cast<String, Object?>();
    final status = '${screen['status']}';
    spans.write(
      '<span class="s-${_esc(status)}">${_esc(screen['screenId'])} '
      '${_esc(status)}</span>',
    );
  }

  return '<div class="evidence">$spans</div>';
}

/// What preflight found, above the tests - because it is what decides
/// whether any of them mean anything.
///
/// Every outcome is shown, deferrals included. "We could not know this
/// yet" is a finding, and leaving it out would let a reader believe
/// everything had been checked.
String _preflight(Object? node) {
  if (node is! Map) return '';
  final checks = (node['checks'] as List?) ?? const [];
  if (checks.isEmpty) return '';

  final rows = checks.map((entry) {
    final check = (entry! as Map).cast<String, Object?>();
    final outcome = '${check['outcome']}';
    final remedy = check['remedy'];
    return '<tr>'
        '<td>${_esc(check['name'])}</td>'
        '<td class="k ${_esc(outcome)}">${_esc(outcome)}</td>'
        '<td class="k"><span class="owner">${_esc(check['class'])}</span></td>'
        '<td><div class="reason">${_esc(check['detail'])}</div>'
        '${remedy == null ? '' : '<div class="reason">&rarr; ${_esc(remedy)}</div>'}'
        '</td>'
        '</tr>';
  }).join();

  return '''
<h2>preflight</h2>
<table>
  <tr><th>Prerequisite</th><th class="k">Outcome</th>
      <th class="k">Owned by</th><th>Detail</th></tr>
  $rows
</table>''';
}

/// What the suite undid on the way out, and whether it managed to.
///
/// Recorded rather than assumed: a teardown nobody checks is a teardown
/// whose leftovers turn up later as a run that behaved differently
/// because a previous run had happened.
String _cleanup(Object? node) {
  if (node is! List || node.isEmpty) return '';

  final rows = node.map((entry) {
    final step = (entry! as Map).cast<String, Object?>();
    final succeeded = step['succeeded'] == true;
    return '<tr>'
        '<td>${_esc(step['name'])}</td>'
        '<td class="k ${succeeded ? 'satisfied' : 'blocked'}">'
        '${succeeded ? 'done' : 'failed'}</td>'
        '<td><div class="reason">${_esc(step['detail'] ?? '')}</div></td>'
        '</tr>';
  }).join();

  return '''
<h2>cleanup</h2>
<table>
  <tr><th>Undone</th><th class="k">Outcome</th><th>Detail</th></tr>
  $rows
</table>''';
}

String _duration(Object? milliseconds) {
  final value = milliseconds is num ? milliseconds.toInt() : 0;
  final seconds = value / 1000;
  if (seconds < 90) return '${seconds.toStringAsFixed(1)}s';
  return '${(seconds / 60).toStringAsFixed(1)}m';
}

String _esc(Object? value) => '$value'
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
