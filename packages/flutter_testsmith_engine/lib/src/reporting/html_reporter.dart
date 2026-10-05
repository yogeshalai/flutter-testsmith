import '../validation/validation_result.dart';
import 'run_result.dart';

/// Renders `result.json` as a page a person can read.
///
/// Takes the decoded JSON rather than the objects, deliberately. The
/// HTML is then a pure function of the file CI consumes, so the two can
/// never disagree - and the renderer can be tested against fixtures with
/// no run required.
///
/// The page is self-sufficient: no stylesheet, script, font or image is
/// fetched from anywhere, and a Content-Security-Policy says so to the
/// browser as well, so it reads the same offline, from an artefact
/// store, or attached to a ticket. The one script on it is a fixed
/// string that shows and hides rows; it never reads a value out of the
/// result, and every value on the page is escaped text.
class HtmlReporter {
  const HtmlReporter();

  String render(Map<String, Object?> result) {
    final screens = (result['screens'] as List?) ?? const [];
    final steps = (result['steps'] as List?) ?? const [];
    final apiChecks = (result['apiChecks'] as List?) ?? const [];

    // The verdict the run recorded, which is the same one the dimension
    // table below prints. This used to be recomputed from the per-screen
    // counts, because `overall` could miss a result carrying no
    // dimension; a report now refuses one, so it cannot.
    //
    // The boolean remains only as a fallback for a `result.json` written
    // before `overall` existed at schema 1.1.
    final verdict = result['overall'] as String? ??
        (result['passed'] == true
            ? ValidationStatus.pass.wire
            : ValidationStatus.fail.wire);

    return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="$_contentSecurityPolicy">
<title>${_esc(result['flow'])} - test report</title>
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
  /* Neither green nor red. A check that could not be run is not a
     defect, and a red pill beside a genuine one teaches people to
     stop reading both. */
  .error { background: #6b4a05; color: #ffeccd; }
  .skip { background: #333; color: #ddd; }
  section { margin: 28px 0; }
  h2 { font-size: 15px; margin: 0 0 10px; }
  table { border-collapse: collapse; width: 100%; font-size: 13px; }
  th, td { text-align: left; padding: 7px 10px;
           border-bottom: 1px solid rgba(128,128,128,.25); vertical-align: top; }
  th { font-weight: 600; opacity: .75; }
  .status { font-weight: 600; }
  .summarised { font-size: 12px; opacity: .7; margin: 10px 0 0; }
  .quiescence { font-size: 12px; opacity: .8; margin: 12px 0 0;
                border-left: 2px solid rgba(128,128,128,.4);
                padding-left: 8px; }
  .quiescence .label { text-transform: uppercase; letter-spacing: .06em;
                       opacity: .7; }
  .s-pass { color: #2e9e63; }
  .s-fail { color: #d2455a; }
  .s-skip { opacity: .6; }
  .s-error { color: #d98324; }
  .detail { font-family: ui-monospace, monospace; font-size: 12px;
            white-space: pre-wrap; opacity: .85; }
  .values { display: flex; gap: 24px; margin-top: 6px; font-size: 12px; }
  .provenance { margin-top: 6px; font-size: 12px; opacity: .8;
                border-left: 2px solid rgba(128,128,128,.4);
                padding-left: 8px; }
  .values div span { display: block; opacity: .6; }
  code { font-family: ui-monospace, monospace; }
  .ai { border: 1px solid rgba(128,128,128,.35); border-radius: 8px;
        padding: 14px 16px; }
  .ai .caveat { font-size: 12px; opacity: .78; margin: 0 0 12px; }
  .ai .summary { margin: 0 0 14px; }
  .claim { display: inline-block; padding: 1px 8px; border-radius: 999px;
           font-size: 11px; font-weight: 600; letter-spacing: .03em;
           white-space: nowrap; }
  .c-confirmed_failure { background: #7a1220; color: #ffd9de; }
  .c-probable_cause { background: #7a5312; color: #ffeccc; }
  .c-hypothesis { background: rgba(128,128,128,.3); }
  .provenance { font-size: 12px; opacity: .65; margin-top: 12px; }
  .dimensions { border-collapse: collapse; margin: 16px 0; width: 100%; }
  .dimensions th { text-align: left; padding: 6px 12px; width: 8rem;
                   font-weight: 600; }
  .dimensions td.status { font-weight: 700; padding: 6px 12px; width: 6rem; }
  .dimensions td.reason { padding: 6px 12px; opacity: .75; }
  .dim-pass td.status { color: #4ec98a; }
  .dim-fail td.status { color: #ff6b81; }
  .dim-error td.status { color: #ffb454; }
  .dim-skip td.status { color: #9aa0a6; }
  .dim-overall th, .dim-overall td { border-top: 2px solid currentColor; }
  .capture { border-left: 3px solid rgba(128,128,128,.5); padding: 6px 10px;
             margin: 0 0 12px; font-size: 13px; }
  .capture .label { font-weight: 700; text-transform: uppercase;
                    letter-spacing: .04em; }
  .capture-active { border-color: #2e9e63; }
  .capture-partial, .capture-unavailable { border-color: #d98324; }
  .capture .scope { font-size: 12px; opacity: .7; margin-top: 4px; }
  .filters { font-size: 12px; margin: 0 0 8px; display: flex; gap: 14px;
             flex-wrap: wrap; }
  .filters[hidden], tr[hidden] { display: none; }
  .when { font-family: ui-monospace, monospace; font-size: 12px;
          white-space: nowrap; }
  .kind { font-size: 11px; text-transform: uppercase; letter-spacing: .05em;
          opacity: .7; }
  .url { font-family: ui-monospace, monospace; font-size: 12px;
         word-break: break-all; }
</style>
</head>
<body>
<h1>${_esc(result['flow'])}</h1>
<div class="meta">
  ${_esc(result['appId'])} &middot; ${_esc(result['device'])} &middot;
  ${_esc(result['startedAt'])} &middot; ${_esc(result['durationMs'])}ms
</div>
<div class="verdict ${_esc(verdict)}">${_esc(verdict.toUpperCase())}</div>
${_dimensionsSection(result)}

${_apiSection(apiChecks)}
${_stepsSection(steps)}
${_networkSection(result)}
${_timelineSection(result)}
${screens.map((s) => _screenSection(s as Map<String, Object?>)).join('\n')}
${_analysisSection((result['aiAnalysis'] as Map?)?.cast<String, Object?>())}
$_filterScript
</body>
</html>
''';
  }


  /// The dimensions and the overall verdict, above everything else.
  ///
  /// First, deliberately. A reader who sees only a green header cannot
  /// tell which sources of truth that verdict speaks for, and a
  /// dimension that was never checked reads as evidence when it is
  /// absent from the page rather than present and marked SKIP.
  String _dimensionsSection(Map<String, Object?> result) {
    final dimensions = result['dimensions'] as Map<String, Object?>?;
    if (dimensions == null) return '';

    final rows = StringBuffer();
    for (final key in const ['ui', 'api', 'figma', 'visual']) {
      final entry = (dimensions[key] as Map?)?.cast<String, Object?>();
      if (entry == null) continue;
      final status = '${entry['status']}';
      final reason = entry['reason'];
      rows.write(
        '<tr class="dim dim-$status">'
        '<th>${key.toUpperCase()}</th>'
        '<td class="status">${status.toUpperCase()}</td>'
        '<td class="reason">${reason == null ? '' : _esc(reason)}</td>'
        '</tr>',
      );
    }

    final overall = '${result['overall']}';
    rows.write(
      '<tr class="dim dim-overall dim-$overall">'
      '<th>OVERALL</th>'
      '<td class="status">${overall.toUpperCase()}</td>'
      '<td></td></tr>',
    );

    return '<table class="dimensions">$rows</table>';
  }

  /// Renders the AI analysis, kept visibly apart from the verdicts.
  ///
  /// Last on the page, in its own box, with the strength of each claim
  /// in its own column and a caveat above everything. A reader must not
  /// be able to mistake a model's explanation for a measurement, so the
  /// page says which it is before it says anything else.
  String _analysisSection(Map<String, Object?>? analysis) {
    if (analysis == null) return '';

    if (analysis['state'] != 'ready') {
      // "Nothing failed" and "the provider was down" are different
      // facts, and the reason distinguishes them.
      return '''
<section>
  <h2>AI analysis</h2>
  <div class="ai"><p class="caveat">Not produced:
  ${_esc(analysis['reason'])}</p></div>
</section>''';
    }

    final findings = (analysis['findings'] as List?) ?? const [];
    final rows = findings.map((raw) {
      final finding = raw! as Map<String, Object?>;
      final claim = '${finding['classification']}';
      final confidence = finding['confidence'];
      final checks = (finding['suggestedChecks'] as List?) ?? const [];

      final extras = StringBuffer();
      if (checks.isNotEmpty) {
        extras.write(
          '<div class="detail">next: ${_esc(checks.join('; '))}</div>',
        );
      }
      if (confidence != null) {
        extras.write(
          '<div class="detail">model confidence ${_esc(confidence)}</div>',
        );
      }

      return '<tr>'
          '<td><span class="claim c-$claim">${_esc(claim)}</span></td>'
          '<td>${_esc(finding['validatorId'])}</td>'
          '<td>${_esc(finding['elementId'] ?? '')}</td>'
          '<td><div>${_esc(finding['explanation'])}</div>$extras</td>'
          '</tr>';
    }).join('\n');

    final table = findings.isEmpty
        ? ''
        : '<table><tr><th>Claim</th><th>Validator</th><th>Element</th>'
            '<th>Explanation</th></tr>\n$rows\n</table>';

    return '''
<section>
  <h2>AI analysis</h2>
  <div class="ai">
    <p class="caveat">Written by a language model from the results above.
    <strong>This is not a verdict.</strong> The pass or fail of this run was
    decided by exact comparisons before the model was asked, and does not
    depend on anything in this box. Any confidence shown is the model's own
    and applies to its explanation, never to a measurement.</p>
    <p class="summary">${_esc(analysis['summary'])}</p>
    $table
    <div class="provenance">
      ${_esc(analysis['provider'])} / ${_esc(analysis['model'])} &middot;
      ${_esc(analysis['promptTokens'])}+${_esc(analysis['completionTokens'])}
      tokens &middot; ${_esc(analysis['latencyMs'])}ms &middot;
      ${_esc(analysis['generatedAt'])}
    </div>
  </div>
</section>''';
  }

  /// The `expectApi` assertions, from the canonical `apiChecks` list.
  ///
  /// The page never had a reader for `apiChecks` at all. What it had was
  /// the API row of the dimension table, which carries one status and -
  /// only when that dimension did not pass - the first decisive message.
  /// So a run whose API assertions all held named none of them, and a
  /// run with three failures named one. That absence is why the steps
  /// table was carrying the assertions: it was the only place on the
  /// page they appeared, which is also why they could not simply be
  /// filtered out of it.
  ///
  /// Read, never re-evaluated. `satisfied` is canonical and already in
  /// the file; deciding here whether an assertion held would give the
  /// page licence to disagree with the JSON beside it.
  ///
  /// Endpoint, status, the screen the request went out on and the
  /// evaluator's own failure lines. No request or response body, as
  /// everywhere else in this report.
  String _apiSection(List<Object?> checks) {
    if (checks.isEmpty) return '';

    final rows = checks.map((raw) {
      final check = raw! as Map<String, Object?>;
      final satisfied = check['satisfied'] == true;
      final status = satisfied ? 'pass' : 'fail';

      // All of them. The dimension row above already shows the first;
      // the rest are the ones that have nowhere else to appear.
      final reasons = ((check['failures'] as List?) ?? const [])
          .map((f) => '<div class="detail">${_esc(f)}</div>')
          .join();

      return '<tr>'
          '<td class="status s-$status">$status</td>'
          '<td>${_esc(check['endpoint'])}$reasons</td>'
          '<td>${_esc(check['status'])}</td>'
          '<td>${_esc(check['screenId'])}</td>'
          '</tr>';
    }).join('\n');

    return '''
<section>
  <h2>API assertions</h2>
  <table><tr><th>Status</th><th>Endpoint</th><th>Answered</th>
  <th>Requested on</th></tr>
  $rows
  </table>
</section>''';
  }

  /// The UI steps: the execution of the user-written test.
  ///
  /// `expectApi` steps are left out, because they have a section of
  /// their own above. The rule that identifies them lives in one place
  /// and is read by every report, so the page and the terminal summary
  /// cannot come to different answers about the same run.
  String _stepsSection(List<Object?> steps) {
    if (steps.isEmpty) return '';

    final ui = <Map<String, Object?>>[];
    for (final raw in steps) {
      final step = raw! as Map<String, Object?>;
      // `kind` from 1.3 onwards, absent in an older artefact. The one
      // helper decides which of those it is looking at; the page does
      // not carry a second copy of that rule.
      if (isApiAssertionStep(
        kind: step['kind'] as String?,
        description: '${step['description']}',
      )) {
        continue;
      }
      ui.add(step);
    }

    final rows = ui.isEmpty
        // Said, rather than left out. "No UI step ran" and "the section
        // was omitted" are different facts, and an absent table reads as
        // the second.
        ? '<tr><td colspan="3">no UI steps ran</td></tr>'
        : ui.map((step) {
            // Why the step did what it did, in the executor's own words.
            // Serialised since the first schema and never read here, so
            // a failing row said what was attempted and nothing about
            // what happened.
            //
            // Rendered only when the step recorded one. Nothing is
            // synthesised from a validation message, a dimension reason
            // or an exception this row never saw.
            final detail = step['detail'];
            final rendered = detail == null || '$detail'.isEmpty
                ? ''
                : '<div class="detail">${_esc(detail)}</div>';

            return '<tr data-k="${_esc(step['status'])}">'
                '<td>${_esc(step['description'])}$rendered</td>'
                '<td class="status s-${_esc(step['status'])}">'
                '${_esc(step['status'])}</td>'
                '<td>${_esc(step['durationMs'])}ms</td></tr>';
          }).join('\n');

    return '''
<section>
  <h2>Steps</h2>
  ${_filters('steps', [for (final s in ui) '${s['status']}'])}
  <table id="steps"><tr><th>Step</th><th>Status</th><th>Took</th></tr>
  $rows
  </table>
</section>''';
  }

  /// What was moving on the screen when it was checked.
  ///
  /// The terminal summary has had a QUIESCENCE section since E2E
  /// reporting was organised by layer, and `quiescence` has been in
  /// `result.json` just as long. The page had no reader for it, so a
  /// screen photographed while something was still animating looked
  /// exactly like one that had settled.
  ///
  /// Context, not a verdict. It says what a PASS on this screen covered;
  /// the status beside the screen id is still the only thing that
  /// decides anything, and nothing here is styled as one.
  ///
  /// The evaluator's own wording, rendered as recorded. It already
  /// counted what was ticking, which of those were permitted and why,
  /// and what was not - a second description here would be a second
  /// thing to drift from the terminal. Nothing is recomputed, and when a
  /// screen recorded no quiescence at all the block is absent rather
  /// than claiming "nothing was ticking" on its behalf.
  String _quiescenceBlock(Object? node) {
    if (node is! Map) return '';
    final quiescence = node.cast<String, Object?>();
    final lines = (quiescence['detail'] as List?) ?? const [];

    // A summary recorded without the evaluator's lines - still evidence,
    // and the three counts are what it has.
    if (lines.isEmpty) {
      return '<div class="quiescence"><span class="label">quiescence</span> '
          '&middot; ticking ${_esc(quiescence['ticking'])}'
          ' &middot; permitted ${_esc(quiescence['permitted'])}'
          ' &middot; unexpected ${_esc(quiescence['unexpected'])}</div>';
    }

    final rendered =
        lines.map((line) => '<div>${_esc(line)}</div>').join();

    return '<div class="quiescence">'
        '<span class="label">quiescence</span>$rendered</div>';
  }

  String _screenSection(Map<String, Object?> screen) {
    final validation = (screen['validation'] as Map?)?.cast<String, Object?>();
    final results = (validation?['results'] as List?) ?? const [];
    // The screen's own verdict, as the run recorded it. Absent from a
    // `result.json` written before schema 1.2, and then simply not
    // shown - re-deriving it here would be the second answer this field
    // exists to remove.
    final status = screen['status'] as String?;
    final exchanges = (screen['exchanges'] as List?) ?? const [];

    // On a screen the run recorded as passing, a row that says only
    // "this passed" is counted rather than printed. Everything else is
    // rendered exactly as before.
    //
    // Keyed on the screen's canonical status, never on the rows: a page
    // that worked out for itself whether a screen passed would be the
    // second answer `ScreenResult.status` exists to remove.
    //
    // A pass is "bare" only when it carries nothing beyond its own
    // message. STOP-1 provenance hangs off *passing* results - the row
    // saying a response was captured on another screen 15 seconds
    // earlier is a PASS, and it is the one line stopping a reader
    // assuming the data belonged to the screen in front of them. So a
    // pass with evidence, or with measured values, is kept. So are
    // skips: a screen that passed because nothing was compared must
    // never read as a screen that was checked.
    final compact = status == 'pass';
    var summarised = 0;

    final rendered = <Map<String, Object?>>[];
    for (final raw in results) {
      final r = raw! as Map<String, Object?>;
      final rowStatus = '${r['status']}';
      final rowEvidence = (r['evidence'] as List?) ?? const [];

      if (compact &&
          rowStatus == 'pass' &&
          rowEvidence.isEmpty &&
          r['expected'] == null &&
          r['actual'] == null) {
        summarised++;
        continue;
      }
      rendered.add(r);
    }

    final resultRows = rendered.map((r) {
      final status = '${r['status']}';
      // Where the data came from, when the screen did not fetch it.
      // STOP-1 requires a report to say so rather than leave a reader to
      // assume the response belonged to the screen in front of them.
      final evidence = <String, String>{
        for (final item in (r['evidence'] as List?) ?? const [])
          if (item is Map)
            item['kind'].toString(): item['reference'].toString(),
      };

      final sourceScreen = evidence['sourceScreen'];
      final provenance = sourceScreen == null
          ? ''
          : '<div class="provenance">data from '
              '<code>${_esc(evidence['sourceEndpoint'])}</code>'
              ', captured on <code>${_esc(sourceScreen)}</code>'
              ' at ${_esc(evidence['sourceCapturedAt'])}'
              ' (${_esc(evidence['sourceAgeSeconds'])}s before this screen'
              ', request ${_esc(evidence['sourceRequestId'])})</div>';

      final values = (r['expected'] != null || r['actual'] != null)
          ? '<div class="values">'
              '<div><span>expected</span><code>${_esc(r['expected'])}</code></div>'
              '<div><span>actual</span><code>${_esc(r['actual'])}</code></div>'
              '</div>'
          : '';
      return '<tr>'
          '<td class="status s-$status">$status</td>'
          '<td>${_esc(r['validatorId'])}</td>'
          '<td>${_esc(r['elementId'] ?? '')}</td>'
          '<td><div class="detail">${_esc(r['message'])}</div>'
          '$provenance$values</td>'
          '</tr>';
    }).join('\n');

    final exchangeRows = exchanges.map((raw) {
      final e = raw! as Map<String, Object?>;
      return '<tr><td>${_esc(e['method'])}</td><td>${_esc(e['path'])}</td>'
          '<td>${_esc(_clip(e['statusCode'] ?? e['error']))}</td>'
          // Absent from 1.5 for a request nobody answered. Written as 0
          // before that, and shown as 0 for such a file: the page renders
          // what the file says rather than guessing what it meant.
          '<td>${e['durationMs'] == null ? 'no response' : '${_esc(e['durationMs'])}ms'}</td></tr>';
    }).join('\n');

    return '''
<section>
  <h2>${_esc(screen['screenId'])}
  ${status == null ? '' : '<span class="verdict $status">'
      '${status.toUpperCase()}</span>'}</h2>
  ${exchanges.isEmpty ? '' : '''
  <table><tr><th>Method</th><th>Path</th><th>Status</th><th>Took</th></tr>
  $exchangeRows
  </table>'''}
  ${_quiescenceBlock(screen['quiescence'])}
  ${summarised == 0 ? '' : '<p class="summarised">$summarised '
      'check${summarised == 1 ? '' : 's'} passed</p>'}
  ${rendered.isEmpty ? '' : '''
  <table style="margin-top:12px">
  <tr><th>Status</th><th>Validator</th><th>Element</th><th>Detail</th></tr>
  $resultRows
  </table>'''}
</section>''';
  }

  /// Every request the run captured, and how much it could have seen.
  ///
  /// The capture statement comes first and is never left out, because
  /// the table under it means nothing without it: an empty table under
  /// "capture unavailable" says nothing about the application, and the
  /// same empty table under "capture on" says it made no call the
  /// capture could see. Neither is "no API calls were made".
  ///
  /// No header, no body. The record carries neither, and this page would
  /// not render them if it did.
  String _networkSection(Map<String, Object?> result) {
    final network = (result['network'] as Map?)?.cast<String, Object?>();
    if (network == null) {
      // A result written before 1.5, or built somewhere other than a
      // device run. Said, because a page with no network section at all
      // reads as a run that made no requests.
      return '''
<section>
  <h2>API calls</h2>
  <div class="capture capture-unavailable"><span class="label">not
  recorded</span> &middot; this result carries no network record, so it
  cannot say which requests the application made.</div>
</section>''';
    }

    final state = '${network['capture']}';
    final reasons = (network['reasons'] as List?) ?? const [];
    final exchanges = [
      for (final raw in (network['exchanges'] as List?) ?? const [])
        if (raw is Map) raw.cast<String, Object?>(),
    ];
    final orphans = network['orphanResponses'];

    final label = switch (state) {
      'active' => 'capture on',
      'partial' => 'capture partial',
      'unavailable' => 'capture unavailable',
      _ => 'capture ${_esc(state)}',
    };
    final reasonLines = reasons.map((r) => '<div>${_esc(r)}</div>').join();

    final timing = state == 'unavailable'
        ? ''
        : '<div class="scope">${_durationClockNote(network['durationClock'])}'
            '</div>';

    final banner = '<div class="capture capture-${_esc(state)}">'
        '<span class="label">$label</span>'
        '$reasonLines'
        '$timing'
        '<div class="scope">Covers ${_esc(network['scope'])}</div>'
        '</div>';
    final took = _tookHeader(network['durationClock']);

    if (exchanges.isEmpty) {
      final none = state == 'unavailable'
          ? 'No request was observed. Capture was not running, so this is '
              'not evidence that none was made.'
          : 'No request was observed on the paths the capture covers.';
      return '''
<section>
  <h2>API calls</h2>
  $banner
  <p class="summarised">${_esc(none)}</p>
</section>''';
    }

    final counts = <String, int>{};
    for (final e in exchanges) {
      final outcome = '${e['outcome']}';
      counts[outcome] = (counts[outcome] ?? 0) + 1;
    }
    final summary = [
      '${exchanges.length} request${exchanges.length == 1 ? '' : 's'}',
      for (final entry in counts.entries)
        '${entry.value} ${_outcomeLabel(entry.key)}',
      if (orphans is int && orphans > 0)
        '$orphans response${orphans == 1 ? '' : 's'} without a request',
    ].join(' &middot; ');

    final rows = exchanges.map((e) {
      final bucket = _statusBucket(e);
      final answer = e['statusCode'] ??
          e['error'] ??
          (e['outcome'] == 'unanswered' ? 'no response' : null);
      final took = e['durationMs'] == null
          ? '&mdash;'
          : '${_esc(e['durationMs'])}ms';
      return '<tr data-k="${_esc(bucket)}">'
          '<td class="when">${_esc(_clock(e['requestedAt']))}</td>'
          '<td>${_esc(e['method'])}</td>'
          '<td class="url">${_esc(_clip(e['url']))}</td>'
          '<td>${_esc(e['screenId'] ?? 'no screen')}</td>'
          '<td class="status s-${_bucketStyle(bucket)}">'
          '${_esc(_clip(answer))}</td>'
          '<td>$took</td></tr>';
    }).join('\n');

    return '''
<section>
  <h2>API calls</h2>
  $banner
  <p class="summarised">$summary</p>
  ${_filters('api-calls', [for (final e in exchanges) _statusBucket(e)])}
  <table id="api-calls"><tr><th>Requested (UTC)</th><th>Method</th>
  <th>URL</th><th>Screen</th><th>Answer</th><th>$took</th></tr>
  $rows
  </table>
</section>''';
  }

  /// What happened when, in two lanes: one per clock.
  ///
  /// A step's moment is the run's start plus its offset on the host's
  /// monotonic stopwatch. A request's is the time the application stamped
  /// on its event, on the device. Nothing in a run measures how far apart
  /// those two clocks are, so the page never sorts one against the other.
  ///
  /// It did, once, and the first device run showed why it must not: the
  /// host's clock was ahead of the handset's by at least 7.2 s, and a
  /// merged list put the login request before the tap that sent it - and
  /// every request before the run's first step. A caveat beside a list
  /// does not stop a reader believing its order. Two lanes, each in its
  /// own clock's order and labelled with it, says only what is known.
  ///
  /// Derived here and never stored: the times are already in the file,
  /// and a stored copy of the order would be a second answer to drift
  /// from the first.
  String _timelineSection(Map<String, Object?> result) {
    final start = DateTime.tryParse('${result['startedAt']}');
    final steps = <({int at, String row})>[];
    var untimedSteps = 0;

    for (final raw in (result['steps'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final step = raw.cast<String, Object?>();
      final offset = step['startedOffsetMs'];
      if (start == null || offset is! int) {
        untimedSteps++;
        continue;
      }
      final at = start.add(Duration(milliseconds: offset));
      steps.add((
        at: offset,
        row: '<tr data-k="${_esc(step['status'])}">'
            '<td class="when">+${_esc(_seconds(offset))}</td>'
            '<td class="when">${_esc(_clock(at.toIso8601String()))}</td>'
            '<td>${_esc(step['description'])}</td>'
            '<td class="status s-${_esc(step['status'])}">'
            '${_esc(step['status'])}</td>'
            '<td>${_esc(step['durationMs'])}ms</td></tr>',
      ));
    }

    final requests = <({DateTime at, String row})>[];
    final network = (result['network'] as Map?)?.cast<String, Object?>();
    for (final raw in (network?['exchanges'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final e = raw.cast<String, Object?>();
      final at = DateTime.tryParse('${e['requestedAt']}');
      if (at == null) continue;
      final bucket = _statusBucket(e);
      final took = e['durationMs'] == null
          ? '&mdash;'
          : '${_esc(e['durationMs'])}ms';
      requests.add((
        at: at,
        row: '<tr data-k="${_esc(bucket)}">'
            '<td class="when">${_esc(_clock(e['requestedAt']))}</td>'
            '<td><span class="url">${_esc(e['method'])} '
            '${_esc(_clip(e['url']))}</span></td>'
            '<td>${_esc(e['screenId'] ?? 'no screen')}</td>'
            '<td class="status s-${_bucketStyle(bucket)}">'
            '${_esc(bucket)}</td>'
            '<td>$took</td></tr>',
      ));
    }

    if (steps.isEmpty && requests.isEmpty) return '';

    final untimed = untimedSteps == 0
        ? ''
        : '<p class="summarised">$untimedSteps '
            'step${untimedSteps == 1 ? ' carries' : 's carry'} no start time '
            'and ${untimedSteps == 1 ? 'is' : 'are'} not placed here.</p>';

    final hostLane = steps.isEmpty
        ? ''
        : '''
  <h3>Steps &middot; host clock</h3>
  <table id="timeline-host"><tr><th>After start</th><th>At (UTC)</th>
  <th>Step</th><th>Status</th><th>Took</th></tr>
  ${_stableSorted(steps, (s) => s.at).map((s) => s.row).join('\n')}
  </table>''';

    final deviceLane = requests.isEmpty
        ? ''
        : '''
  <h3>Requests &middot; device clock</h3>
  <table id="timeline-device"><tr><th>Requested (UTC)</th><th>Request</th>
  <th>Screen</th><th>Answer</th><th>${_tookHeader(network?['durationClock'])}</th></tr>
  ${_stableSorted(requests, (r) => r.at).map((r) => r.row).join('\n')}
  </table>''';

    return '''
<section>
  <h2>Timeline</h2>
  <p class="summarised">Two clocks. Steps are timed on the machine running
  testsmith, requests by the application on the device, and this run did
  not measure the difference between them - so each lane is in its own
  clock's order, and a time in one lane cannot be compared with a time in
  the other.</p>
  $untimed
  $hostLane
  $deviceLane
</section>''';
  }

  /// [items] ordered by [key], keeping the recorded order for ties.
  static List<T> _stableSorted<T, K extends Comparable<Object>>(
    List<T> items,
    K Function(T) key,
  ) {
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])]
      ..sort((a, b) {
        final byKey = key(a.$2).compareTo(key(b.$2));
        return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
      });
    return [for (final pair in indexed) pair.$2];
  }

  /// Milliseconds as seconds with three decimals, for the host lane.
  static String _seconds(int ms) =>
      '${ms ~/ 1000}.${(ms % 1000).toString().padLeft(3, '0')}s';

  /// What the durations on the page were measured with, in one sentence.
  ///
  /// From `network.durationClock` as the run recorded it. A file without
  /// the key - anything written before 1.6 - is said to be unrecorded,
  /// never assumed to be either clock: relabelling an old artefact is how a
  /// report starts disagreeing with the run it describes.
  static String _durationClockNote(Object? clock) => switch (clock) {
        'monotonic' => 'Durations: measured by the application on a '
            'monotonic clock, from before the connection was opened to the '
            'end of the response body or the error.',
        'wall' => 'Durations: measured by an older SDK as the difference of '
            'two wall-clock readings, from after the connection was '
            'established. A clock change during a request distorts its '
            'duration.',
        null => 'Durations: the clock they were measured on was not '
            'recorded. This result was written before schema 1.6.',
        _ => 'Durations: measured on a clock this report does not know '
            '(${_esc(clock)}).',
      };

  /// The duration column's heading, naming the clock.
  static String _tookHeader(Object? clock) => switch (clock) {
        'monotonic' => 'Took (monotonic)',
        'wall' => 'Took (wall clock)',
        null => 'Took (clock not recorded)',
        _ => 'Took (${_esc(clock)})',
      };

  /// A row's filter key: the status class for an answered request, and
  /// the outcome itself for one that never got a status.
  static String _statusBucket(Map<String, Object?> exchange) {
    final code = exchange['statusCode'];
    if (code is int) return '${code ~/ 100}xx';
    final outcome = exchange['outcome'];
    return outcome == null ? 'unknown' : '$outcome';
  }

  /// The colour a bucket borrows from the verdict palette. Context, not a
  /// verdict: a 404 the flow expected is not a failure of the run.
  static String _bucketStyle(String bucket) => switch (bucket) {
        '2xx' || '3xx' => 'pass',
        '4xx' || '5xx' || 'failed' => 'fail',
        'unanswered' => 'error',
        _ => 'skip',
      };

  static String _outcomeLabel(String outcome) => switch (outcome) {
        'success' => 'succeeded',
        'httpError' => 'answered with an error status',
        'failed' => 'failed without a response',
        'unanswered' => 'unanswered when the run ended',
        _ => _esc(outcome),
      };

  /// The checkboxes above a table, one per key its rows carry.
  ///
  /// Hidden until the script shows them, so a reader with scripts off
  /// sees every row and no control that does nothing.
  static String _filters(String tableId, Iterable<String> keys) {
    final distinct = <String>{...keys};
    if (distinct.length < 2) return '';
    final boxes = distinct
        .map((k) => '<label><input type="checkbox" value="${_esc(k)}" '
            'checked> ${_esc(k)}</label>')
        .join();
    return '<div class="filters" data-filter-for="$tableId" hidden>'
        '$boxes</div>';
  }

  /// `HH:MM:SS.mmm` out of an ISO-8601 timestamp, or the text as written
  /// when it is not one.
  static String _clock(Object? iso) {
    if (iso == null) return '';
    final parsed = DateTime.tryParse('$iso');
    if (parsed == null) return '$iso';
    final t = parsed.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// A captured value cut to a length a table can hold.
  ///
  /// The file keeps all of it; the page says how much it left out, so a
  /// shortened URL is never mistaken for the whole one.
  static Object? _clip(Object? value, {int max = 400}) {
    if (value == null) return null;
    final text = '$value';
    if (text.length <= max) return value;
    return '${text.substring(0, max)}… '
        '(${text.length - max} more characters in result.json)';
  }

  /// Nothing loads from anywhere; inline style and the one inline script
  /// below are all the page has.
  static const String _contentSecurityPolicy =
      "default-src 'none'; style-src 'unsafe-inline'; "
      "script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'";

  /// Shows and hides rows by the `data-k` each carries. Fixed text: it
  /// reads attributes this renderer wrote, never a value from the result.
  static const String _filterScript = '''
<script>
(function () {
  var groups = document.querySelectorAll('[data-filter-for]');
  for (var g = 0; g < groups.length; g++) {
    (function (group) {
      var table = document.getElementById(group.getAttribute('data-filter-for'));
      if (!table) return;
      function apply() {
        var on = {};
        var boxes = group.querySelectorAll('input[type=checkbox]');
        for (var i = 0; i < boxes.length; i++) on[boxes[i].value] = boxes[i].checked;
        var rows = table.querySelectorAll('tr[data-k]');
        for (var j = 0; j < rows.length; j++) {
          rows[j].hidden = on[rows[j].getAttribute('data-k')] === false;
        }
      }
      group.addEventListener('change', apply);
      group.hidden = false;
    })(groups[g]);
  }
})();
</script>''';

  /// Escapes everything interpolated into the page.
  ///
  /// Report content includes captured API bodies, which are attacker-
  /// influenced in the general case; an unescaped one could rewrite the
  /// report it appears in.
  static String _esc(Object? value) {
    if (value == null) return '';
    return value
        .toString()
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
