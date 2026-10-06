// The HTML report's API-call table, timeline and filters.
//
// Rendered from `result.json` alone, as every section of the page is, so
// each case below is a JSON fixture shaped the way RunResult writes it.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

const _start = '2026-10-02T09:00:00.000Z';

Map<String, Object?> _exchange({
  String id = 'r1',
  String method = 'GET',
  String url = 'http://api/products',
  String? screenId = '/home',
  String requestedAt = '2026-10-02T09:00:01.000000Z',
  String outcome = 'success',
  int? statusCode = 200,
  String? error,
  int? durationMs = 80,
}) =>
    {
      'requestId': id,
      'method': method,
      'url': url,
      'screenId': ?screenId,
      'requestedAt': requestedAt,
      'outcome': outcome,
      'statusCode': ?statusCode,
      'error': ?error,
      'durationMs': ?durationMs,
    };

/// A network record as a file holds it. [clock] null is what every 1.5
/// artefact looks like: no `durationClock` key at all.
Map<String, Object?> _network({
  String capture = 'active',
  List<String> reasons = const [],
  List<Map<String, Object?>> exchanges = const [],
  int orphans = 0,
  String? clock,
}) =>
    {
      'capture': capture,
      'durationClock': ?clock,
      'scope': NetworkRecord.scope,
      if (reasons.isNotEmpty) 'reasons': reasons,
      'orphanResponses': orphans,
      'exchanges': exchanges,
    };

String _page({
  Map<String, Object?>? network,
  List<Map<String, Object?>> steps = const [],
  List<Map<String, Object?>> screens = const [],
}) =>
    const HtmlReporter().render({
      'resultSchemaVersion': '1.5',
      'flow': 'browse',
      'appId': 'com.example.shop',
      'device': 'pixel-7',
      'startedAt': _start,
      'durationMs': 3000,
      'passed': true,
      'overall': 'pass',
      'steps': steps,
      'screens': screens,
      'network': ?network,
    });

String _section(String html, String heading) {
  final start = html.indexOf('<h2>$heading</h2>');
  expect(start, isNonNegative, reason: 'no "$heading" section');
  final end = html.indexOf('</section>', start);
  return html.substring(start, end);
}

void main() {
  group('the capture statement', () {
    test('a result with no network record says it records none', () {
      // A 1.4 file, or one not built from a device run. An absent
      // section would read as "no calls were made".
      final api = _section(_page(), 'API calls');

      expect(api, contains('not'));
      expect(api, contains('no network record'));
    });

    test('unavailable capture says an empty table is not evidence', () {
      final api = _section(
        _page(network: _network(
          capture: 'unavailable',
          reasons: ['the application did not offer network capture'],
        )),
        'API calls',
      );

      expect(api, contains('capture unavailable'));
      expect(api, contains('not evidence that none was made'));
      expect(api, isNot(contains('<table')));
    });

    test('partial capture lists every reason', () {
      final api = _section(
        _page(network: _network(
          capture: 'partial',
          reasons: ['dropped 3 events', 'the connection ended'],
          exchanges: [_exchange()],
        )),
        'API calls',
      );

      expect(api, contains('capture partial'));
      expect(api, contains('dropped 3 events'));
      expect(api, contains('the connection ended'));
    });

    test('active capture still states what it covers', () {
      final api = _section(
        _page(network: _network(exchanges: [_exchange()])),
        'API calls',
      );

      expect(api, contains('capture on'));
      expect(api, contains('dart:io HttpClient'));
      expect(api, contains('Not seen'));
    });

    test('active with nothing captured does not say "no calls were made"',
        () {
      final api = _section(_page(network: _network()), 'API calls');

      expect(api, contains('on the paths the capture covers'));
    });
  });

  group('which clock the durations were measured on', () {
    String page(String? clock) => _page(
          steps: [
            {'description': 'tap a', 'kind': 'tap', 'status': 'ok',
              'startedOffsetMs': 0, 'durationMs': 5},
          ],
          network: _network(clock: clock, exchanges: [_exchange()]),
        );

    test('monotonic is named in the banner and both duration columns', () {
      final html = page('monotonic');
      final api = _section(html, 'API calls');
      final timeline = _section(html, 'Timeline');

      expect(api, contains('measured by the application on a monotonic '
          'clock'));
      expect(api, contains('Took (monotonic)'));
      expect(timeline, contains('Took (monotonic)'));
    });

    test('wall is named as an older SDK, with what that costs', () {
      final html = page('wall');
      final api = _section(html, 'API calls');

      expect(api, contains('older SDK'));
      expect(api, contains('A clock change during a request distorts'));
      expect(api, contains('Took (wall clock)'));
      expect(_section(html, 'Timeline'), contains('Took (wall clock)'));
      expect(api, isNot(contains('monotonic')));
    });

    test('a 1.5 artefact is not recorded, and never called monotonic', () {
      // The fixture this file has always used: resultSchemaVersion 1.5,
      // no durationClock. Relabelling it would claim a measurement its SDK
      // never made.
      final html = page(null);
      final api = _section(html, 'API calls');

      expect(api, contains('the clock they were measured on was not '
          'recorded'));
      expect(api, contains('Took (clock not recorded)'));
      expect(html, isNot(contains('monotonic')));
      expect(html, isNot(contains('Took (wall clock)')));
    });

    test('unavailable capture has no durations, so no clock line', () {
      final api = _section(
        _page(network: _network(
          capture: 'unavailable',
          reasons: ['the application did not offer network capture'],
        )),
        'API calls',
      );

      expect(api, isNot(contains('Durations:')));
    });

    test('an unknown clock from a tampered file is escaped, not trusted', () {
      final html = page('<script>x()</script>');

      expect(html, isNot(contains('<script>x()')));
      expect(html, isNot(contains('monotonic')));
      expect(html, contains('a clock this report does not know'));
    });
  });

  group('the API-call table', () {
    test('one row per request: time, method, URL, screen, answer, duration',
        () {
      final api = _section(
        _page(network: _network(exchanges: [_exchange()])),
        'API calls',
      );

      expect(api, contains('09:00:01.000'));
      expect(api, contains('GET'));
      expect(api, contains('http://api/products'));
      expect(api, contains('/home'));
      expect(api, contains('200'));
      expect(api, contains('80ms'));
    });

    test('HTTP errors, exceptions, timeouts and silence are told apart', () {
      final api = _section(
        _page(network: _network(exchanges: [
          _exchange(id: 'a', statusCode: 404, outcome: 'httpError'),
          _exchange(id: 'b', statusCode: 503, outcome: 'httpError'),
          _exchange(id: 'c', statusCode: null, outcome: 'failed',
              error: 'SocketException: Connection refused', durationMs: 3),
          _exchange(id: 'd', statusCode: null, outcome: 'failed',
              error: 'TimeoutException after 0:00:30', durationMs: 30000),
          _exchange(id: 'e', statusCode: null, outcome: 'unanswered',
              durationMs: null),
        ])),
        'API calls',
      );

      expect(api, contains('data-k="4xx"'));
      expect(api, contains('data-k="5xx"'));
      expect(api, contains('Connection refused'));
      expect(api, contains('TimeoutException'));
      expect(api, contains('30000ms'));
      expect(api, contains('data-k="unanswered"'));
      expect(api, contains('no response'));
      expect(api, contains('2 answered with an error status'));
      expect(api, contains('2 failed without a response'));
      expect(api, contains('1 unanswered when the run ended'));
    });

    test('an unanswered request shows no duration, not 0ms', () {
      final api = _section(
        _page(network: _network(exchanges: [
          _exchange(statusCode: null, outcome: 'unanswered', durationMs: null),
        ])),
        'API calls',
      );

      expect(api, isNot(contains('0ms')));
      expect(api, contains('&mdash;'));
    });

    test('a request no screen owns says so', () {
      final api = _section(
        _page(network: _network(exchanges: [_exchange(screenId: null)])),
        'API calls',
      );

      expect(api, contains('no screen'));
    });

    test('orphaned responses are counted in the summary', () {
      final api = _section(
        _page(network: _network(
            capture: 'partial', reasons: ['x'], exchanges: [_exchange()],
            orphans: 2)),
        'API calls',
      );

      expect(api, contains('2 responses without a request'));
    });

    test('a very long URL is shortened on the page and says by how much', () {
      final long = 'http://api/search?q=${'a' * 1000}';
      final api = _section(
        _page(network: _network(exchanges: [_exchange(url: long)])),
        'API calls',
      );

      expect(api, isNot(contains(long)));
      expect(api, contains('more characters in result.json'));
    });
  });

  group('untrusted text', () {
    test('a URL, method, screen or error cannot inject markup', () {
      final html = _page(network: _network(exchanges: [
        _exchange(
          method: '<b>GET</b>',
          url: 'http://x/"><script>alert(1)</script>',
          screenId: '<img src=x onerror=alert(1)>',
          statusCode: null,
          outcome: 'failed',
          error: '</td><script>alert(2)</script>',
        ),
      ]));

      expect(html, isNot(contains('<script>alert')));
      expect(html, isNot(contains('<img src=x')));
      expect(html, isNot(contains('<b>GET</b>')));
      expect(html, contains('&lt;script&gt;alert(1)'));
    });

    test('a captured URL is text, never a link', () {
      final html = _page(network: _network(
          exchanges: [_exchange(url: 'javascript:alert(1)')]));

      expect(html, isNot(contains('href="javascript')));
      expect(html, isNot(contains('<a ')));
    });

    test('an outcome from a tampered file is escaped in the filter too', () {
      final html = _page(network: _network(exchanges: [
        _exchange(statusCode: null, outcome: '"><script>x()</script>'),
        _exchange(id: 'r2'),
      ]));

      expect(html, isNot(contains('<script>x()')));
    });
  });

  group('secrets', () {
    test('a header or body that reached the file is still not rendered', () {
      // The record never carries them. A file edited to carry them anyway
      // must not get them onto the page.
      final exchange = _exchange()
        ..['headers'] = {'authorization': 'Bearer SECRET-HEADER'}
        ..['body'] = '{"password":"SECRET-BODY"}';
      final html = _page(network: _network(exchanges: [exchange]));

      expect(html, isNot(contains('SECRET-HEADER')));
      expect(html, isNot(contains('SECRET-BODY')));
    });

    test('a redacted query value stays redacted', () {
      final html = _page(network: _network(exchanges: [
        _exchange(url: 'http://api/a?access_token=[REDACTED]'),
      ]));

      expect(html, contains('access_token=[REDACTED]'));
    });
  });

  group('offline', () {
    test('the page loads nothing from anywhere', () {
      final html = _page(network: _network(exchanges: [_exchange()]));

      expect(html, isNot(contains('<link')));
      expect(html, isNot(contains(' src=')));
      expect(html, isNot(contains('@import')));
      expect(html, isNot(contains('url(')));
      expect(html, contains('Content-Security-Policy'));
      expect(html, contains("default-src 'none'"));
    });

    test('the one script reads no value from the result', () {
      final html = _page(network: _network(exchanges: [
        _exchange(),
        _exchange(id: 'r2', statusCode: 500, outcome: 'httpError'),
      ]));
      final script = html.substring(
          html.indexOf('<script>'), html.indexOf('</script>'));

      expect('<script>'.allMatches(html), hasLength(1));
      expect(script, isNot(contains('innerHTML')));
      expect(script, isNot(contains('eval')));
      expect(script, isNot(contains('api/products')));
    });
  });

  group('filters', () {
    test('offered where rows differ, hidden until the script shows them', () {
      final html = _page(network: _network(exchanges: [
        _exchange(),
        _exchange(id: 'r2', statusCode: 500, outcome: 'httpError'),
      ]));

      expect(html, contains('data-filter-for="api-calls" hidden'));
      expect(html, contains('value="2xx"'));
      expect(html, contains('value="5xx"'));
    });

    test('not offered when every row is the same kind', () {
      final html = _page(network: _network(exchanges: [_exchange()]));

      expect(html, isNot(contains('data-filter-for="api-calls"')));
    });

    test('steps can be filtered by outcome', () {
      final html = _page(steps: [
        {'description': 'tap a', 'kind': 'tap', 'status': 'ok',
          'durationMs': 5},
        {'description': 'tap b', 'kind': 'tap', 'status': 'failed',
          'durationMs': 5, 'detail': 'missing'},
      ]);

      expect(html, contains('data-filter-for="steps"'));
      expect(html, contains('<tr data-k="failed">'));
    });
  });

  group('the timeline', () {
    // The first device run (docs/evidence/schema-1.5-device-run.md): the
    // login request is stamped 16:05:14.78 on the device and was sent by a
    // tap that began at host time 16:05:22.0, so the host's clock was ahead
    // by at least 7.2 s.
    Map<String, Object?> skewedRun() => {
          'steps': [
            {'description': 'launch the app', 'kind': 'launchApp',
              'status': 'ok', 'startedOffsetMs': 0, 'durationMs': 1},
            {'description': 'tap "login.submit"', 'kind': 'tap',
              'status': 'ok', 'startedOffsetMs': 2961, 'durationMs': 628},
            {'description': 'tap "home.open_product"', 'kind': 'tap',
              'status': 'ok', 'startedOffsetMs': 5915, 'durationMs': 179},
          ],
          'network': _network(exchanges: [
            _exchange(id: 'home', url: 'http://api/home/summary',
                screenId: '/home',
                requestedAt: '2026-10-02T16:05:15.292724Z'),
            _exchange(id: 'login', method: 'POST',
                url: 'http://api/auth/login', screenId: '/login',
                requestedAt: '2026-10-02T16:05:14.779703Z'),
          ]),
        };

    String skewedTimeline() {
      final run = skewedRun();
      final html = const HtmlReporter().render({
        'flow': 'product_details',
        'startedAt': '2026-10-02T16:05:19.039098Z',
        'overall': 'pass',
        'screens': const <Object?>[],
        ...run,
      });
      return _section(html, 'Timeline');
    }

    String lane(String timeline, String id) {
      final start = timeline.indexOf('<table id="$id">');
      expect(start, isNonNegative, reason: 'no lane $id');
      return timeline.substring(start, timeline.indexOf('</table>', start));
    }

    test('the two clocks are never sorted into one list', () {
      // Merged, every request here sorts before the run's first step -
      // the login request ahead of the tap that sent it.
      final timeline = skewedTimeline();
      final host = lane(timeline, 'timeline-host');
      final device = lane(timeline, 'timeline-device');

      expect(host, isNot(contains('http://api')));
      expect(device, isNot(contains('login.submit')));
      expect(timeline.indexOf('<table id="timeline-host">'),
          lessThan(timeline.indexOf('<table id="timeline-device">')));
    });

    test('each lane is in its own clock order and says which clock', () {
      final timeline = skewedTimeline();
      final host = lane(timeline, 'timeline-host');
      final device = lane(timeline, 'timeline-device');

      expect(timeline, contains('Steps &middot; host clock'));
      expect(timeline, contains('Requests &middot; device clock'));
      expect(host.indexOf('launch the app'),
          lessThan(host.indexOf('login.submit')));
      expect(host.indexOf('login.submit'),
          lessThan(host.indexOf('home.open_product')));
      // Recorded home-then-login; issued login-then-home on the device.
      expect(device.indexOf('auth/login'),
          lessThan(device.indexOf('home/summary')));
    });

    test('a step shows its monotonic offset and the host time it implies',
        () {
      final host = lane(skewedTimeline(), 'timeline-host');

      expect(host, contains('+2.961s'));
      expect(host, contains('16:05:22.000'));
    });

    test('says the difference between the clocks was not measured', () {
      final timeline = _section(
        _page(network: _network(exchanges: [_exchange()])),
        'Timeline',
      );

      expect(timeline, contains('did\n  not measure the difference'));
      expect(timeline, contains('cannot be compared'));
    });

    test('a step with no start time is counted, never placed at zero', () {
      // A 1.4 artefact: its steps carry no offset.
      final timeline = _section(
        _page(
          steps: [
            {'description': 'old step', 'kind': 'tap', 'status': 'ok',
              'durationMs': 5},
          ],
          network: _network(exchanges: [_exchange()]),
        ),
        'Timeline',
      );

      expect(timeline, isNot(contains('old step')));
      expect(timeline, contains('1 step carries no start time'));
    });

    test('is absent when nothing in the file has a time', () {
      final html = _page(steps: [
        {'description': 'old step', 'kind': 'tap', 'status': 'ok',
          'durationMs': 5},
      ]);

      expect(html, isNot(contains('<h2>Timeline</h2>')));
    });
  });

  group('the per-screen table', () {
    test('an unanswered exchange reads "no response", not 0ms', () {
      final html = _page(screens: [
        {
          'screenId': '/home',
          'status': 'pass',
          'validation': {'results': <Object?>[]},
          'exchanges': [
            {'requestId': 'r1', 'method': 'GET', 'path': '/hangs'},
          ],
        },
      ]);

      final start = html.indexOf('<h2>/home');
      expect(start, isNonNegative);
      final screen = html.substring(start, html.indexOf('</section>', start));
      expect(screen, contains('no response'));
      expect(screen, isNot(contains('>ms<')));
    });
  });

  group('one model, two renderings', () {
    test('a real RunResult renders through its own JSON', () {
      final run = RunResult(
        flowName: 'browse',
        appId: 'com.example.shop',
        device: 'pixel-7',
        startedAt: DateTime.utc(2026, 10, 2, 9),
        duration: const Duration(seconds: 3),
        steps: const [
          StepOutcome(description: 'tap a', kind: StepKind.tap,
              status: StepStatus.ok, durationMs: 5, startedOffsetMs: 100),
        ],
        screens: const [],
        sessionId: 'session-1',
        network: NetworkRecord(
          state: NetworkCaptureState.active,
          exchanges: [
            NetworkExchange(
              requestId: 'r1', method: 'GET', url: 'http://api/x',
              requestedAt: DateTime.utc(2026, 10, 2, 9, 0, 0, 500),
              outcome: ExchangeOutcome.unanswered),
          ],
        ),
      );
      // Through an encode and decode, as the CLI writes and a later
      // reader would load it.
      final json =
          jsonDecode(jsonEncode(run.toJson())) as Map<String, Object?>;
      final html = const HtmlReporter().render(json);

      expect(html, contains('http://api/x'));
      expect(html, contains('<h2>Timeline</h2>'));
      expect(html, contains('1 unanswered when the run ended'));
    });
  });
}
