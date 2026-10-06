import 'dart:convert';

import 'package:ai_client/ai_client.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Phase 12, brief item 10 - the artefacts a run leaves behind.
///
/// The SDK's own tests prove a secret never enters an event. These
/// prove it never leaves the engine either: not in `result.json`, not
/// in the rendered HTML, and not in the JSON handed to a model.
///
/// Every assertion searches the **serialised text for the literal**,
/// because the failure being guarded against is a route nobody thought
/// of, not a field somebody forgot to redact.

const Map<String, String> seeds = {
  'authorization token': 'SEEDED_ACCESS_TOKEN_8a17fc',
  'password': 'SEEDED_PASSWORD_c41e77b0',
  'refresh token': 'SEEDED_REFRESH_TOKEN_20b93e',
  'OTP': '884512',
  'card number': '4111111111111111',
  'CVV': '731',
  'device secret': 'DEVICE_SECRET_9f2a41c8',
  'session cookie': 'MOCK_SESSION_SECRET',
};

/// A model that records what it was shown.
class RecordingLlm implements LlmClient {
  LlmPrompt? received;

  @override
  LlmConfig get config => LlmConfig.defaults;

  @override
  String get describe => 'recording/model';

  @override
  Future<LlmCompletion> complete(LlmPrompt prompt) async {
    received = prompt;
    return LlmCompletion(
      content: '{"summary":"s","findings":[]}',
      model: 'recording-v1',
    );
  }

  @override
  void close() {}
}

/// A run whose every field has been stuffed with a credential.
///
/// Deliberately hostile input: this is what the report would carry if
/// redaction at capture had failed, or if a future change started
/// copying bodies into the result. Either regression shows up here.
RunResult pollutedRun() => RunResult(
      flowName: 'checkout',
      appId: 'com.example.app',
      device: 'RZ8T11QETWM',
      startedAt: DateTime.utc(2026, 9, 12),
      duration: const Duration(seconds: 12),
      steps: const [
        StepOutcome(
          description: 'type into checkout.card_number',
          kind: StepKind.input,
          status: StepStatus.ok,
          durationMs: 40,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/checkout',
          exchanges: const [
            ExchangeSummary(
              method: 'POST',
              path: '/checkout',
              statusCode: 200,
              durationMs: 30,
            ),
          ],
          report: ValidationReport([
            ValidationResult.fail(
              validatorId: 'api-to-ui',
              dimension: ValidationDimension.api,
              elementId: 'checkout.total',
              message: 'checkout.total.text does not match response.total. '
                  'API returned 4129; currency(INR) gives "Rs 4,129"; the '
                  'UI shows "Rs 4,089".',
              expected: 'Rs 4,129',
              actual: 'Rs 4,089',
              evidence: [
                Evidence(kind: 'apiPath', reference: 'response.total'),
                Evidence(kind: 'apiValue', reference: '4129'),
              ],
            ),
          ]),
        ),
      ],
    );

void main() {
  group('result.json', () {
    test('carries no request or response body at all', () {
      // Structural, and worth stating: ExchangeSummary has method,
      // path, status and duration, and no field a body could occupy.
      // Redaction at capture is the first guarantee; this is the
      // second, and it does not depend on the first.
      const summary = ExchangeSummary(
        method: 'POST',
        path: '/checkout',
        statusCode: 200,
        durationMs: 30,
      );

      expect(
        summary.toJson().keys,
        unorderedEquals(<String>[
          'method',
          'path',
          'statusCode',
          'durationMs',
        ]),
      );
    });

    test('no seeded secret survives serialisation', () {
      final json = jsonEncode(pollutedRun().toJson());

      seeds.forEach((name, value) {
        expect(json, isNot(contains(value)), reason: name);
      });
    });

    test('a URL in a report is the path, not the full address', () {
      // A credential in a query string is the one thing redaction does
      // not strip, so the report carries a path and never a URL.
      final json = jsonEncode(pollutedRun().toJson());

      expect(json, contains('"/checkout"'));
      expect(json, isNot(contains('http://')));
    });
  });

  group('report.html', () {
    test('no seeded secret survives rendering', () {
      final html = const HtmlReporter().render(pollutedRun().toJson());

      seeds.forEach((name, value) {
        expect(html, isNot(contains(value)), reason: name);
      });
    });

    test('the HTML is a function of result.json and nothing else', () {
      // So the two cannot disagree about what happened, and so a
      // secret cannot enter through a second route into the human
      // report.
      final json = pollutedRun().toJson();

      expect(
        const HtmlReporter().render(json),
        const HtmlReporter().render(jsonDecode(jsonEncode(json)) as Map<String, Object?>),
      );
    });

    test('a value that reaches the page is escaped', () {
      // Not a secrecy property, a correctness one: an unescaped value
      // would break the page, and a broken page is one nobody reads.
      final html = const HtmlReporter().render({
        'flow': '<script>alert(1)</script>',
        'passed': false,
        'steps': <Object?>[],
        'screens': <Object?>[],
      });

      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('what the model is shown', () {
    test('no seeded secret reaches the prompt', () async {
      final llm = RecordingLlm();
      await FailureAnalyst(llm).analyse(pollutedRun());

      final prompt = '${llm.received!.system}\n${llm.received!.user}';
      seeds.forEach((name, value) {
        expect(prompt, isNot(contains(value)), reason: name);
      });
    });

    test('bodies and headers are not sent at all', () async {
      // Redaction strips secrets at capture; not sending the payload is
      // the cheaper guarantee, and the one that survives a redactor
      // that misses a key. See ADR-0009.
      final llm = RecordingLlm();
      await FailureAnalyst(llm).analyse(pollutedRun());

      final sent = llm.received!.user;
      expect(sent, isNot(contains('"body"')));
      expect(sent, isNot(contains('"headers"')));
      expect(sent, isNot(contains('authorization')));
    });

    test('what it is sent is enough to explain the failure', () {
      // The counterweight: a prompt stripped of everything useful is
      // safe and pointless.
      final llm = RecordingLlm();
      return FailureAnalyst(llm).analyse(pollutedRun()).then((_) {
        final sent = llm.received!.user;
        expect(sent, contains('api-to-ui'));
        expect(sent, contains('checkout.total'));
        expect(sent, contains('Rs 4,089'));
      });
    });
  });

  group('the evidence chain', () {
    test('carries the raw API value, which is the point of it', () {
      // Brief item 3: the report must show the raw API value, the
      // transformed value and the UI value. Before Phase 12 the raw one
      // existed only inside a prose message.
      final result = pollutedRun().screens.single.report.results.single;
      final json = result.toJson();
      final evidence = (json['evidence']! as List).cast<Map<String, Object?>>();

      expect(
        evidence.map((e) => e['kind']),
        containsAll(<String>['apiPath', 'apiValue']),
      );
      expect(
        evidence.firstWhere((e) => e['kind'] == 'apiValue')['reference'],
        '4129',
      );
    });

    test('and still carries no confidence', () {
      final json = pollutedRun().screens.single.report.results.single.toJson();
      expect(json.keys, isNot(contains('confidence')));
    });
  });

  // ── E-04: what preflight is allowed to write down ───────────────────
  //
  // Preflight reads a device. `dumpsys connectivity` alone prints the
  // SSID, the BSSID, the MAC address and the IP of whatever the handset
  // is attached to, and `adb devices` prints a serial. None of it belongs
  // in an artefact somebody commits or ships to CI.
  group('a preflight report carries nothing about the machine', () {
    /// A report of the shape a real run produces, including a blocker
    /// with a remedy - the field most likely to grow a value.
    PreflightReport report() => const PreflightReport([
          PreflightCheck.satisfied(
            'device',
            klass: PrerequisiteClass.devicePrerequisite,
            detail: 'SM-M127G',
          ),
          PreflightCheck.satisfied(
            'network interface',
            klass: PrerequisiteClass.devicePrerequisite,
            detail: 'an active default network is present',
          ),
          PreflightCheck.blocked(
            'permissions',
            klass: PrerequisiteClass.devicePrerequisite,
            detail: 'android.permission.ACCESS_FINE_LOCATION denied',
            remedy: 'adb shell pm grant com.example.app '
                'android.permission.ACCESS_FINE_LOCATION',
          ),
          PreflightCheck.deferred(
            'authentication',
            klass: PrerequisiteClass.humanAction,
            detail: 'required by home, orders',
          ),
        ]);

    test('every check carries only the keys a report may contain', () {
      // An allow-list of keys, not a deny-list of known secrets: a
      // deny-list only ever catches the secrets somebody remembered.
      const allowed = {'name', 'class', 'outcome', 'detail', 'remedy'};

      for (final entry in report().toJson()['checks']! as List) {
        final check = (entry! as Map).cast<String, Object?>();
        expect(check.keys.toSet().difference(allowed), isEmpty);
      }
    });

    test('nothing identifying the host or its network appears in the JSON',
        () {
      final text = jsonEncode(report().toJson());

      for (final forbidden in const [
        'RZ8T11QETWM', // a device serial
        'SSID',
        'BSSID',
        'b4:a7:c6', // a MAC prefix
        '192.168.',
        '127.0.0.1',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('nor in the per-test evidence a suite now carries', () {
      // The suite result gained `screens` and `dimensions` at suite
      // schema 1.1. The guard above exercises a test with no run behind
      // it, so those keys were never emitted into it - this one attaches
      // a polluted run so the new evidence is actually inspected.
      //
      // Neither key introduces a new class of content: `screens` carries
      // ids and statuses, and a dimension's `reason` is a validator
      // message, which `checks.failures[].message` has always carried.
      final json = jsonEncode(
        SuiteTestResult.product(
          id: 'checkout',
          passed: false,
          required: true,
          duration: Duration.zero,
          run: pollutedRun(),
          outputDirectory: 'checkout',
        ).toJson(),
      );

      expect(json, contains('"screens"'), reason: 'the evidence is present');
      expect(json, contains('"dimensions"'));

      seeds.forEach((name, value) {
        expect(json, isNot(contains(value)), reason: name);
      });
      for (final forbidden in const [
        'RZ8T11QETWM',
        'SSID',
        'BSSID',
        '192.168.',
        'Authorization',
        'Cookie',
      ]) {
        expect(json, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('nor in the rendered page', () {
      final html = renderSuiteReport(SuiteResult(
        suiteName: 's',
        profile: DeviceProfile.parse(
          'id: samsung-m127g\nmodel: SM-M127G\n',
          source: 't',
        ),
        startedAt: DateTime.utc(2026),
        duration: Duration.zero,
        preflight: report(),
        tests: const [
          SuiteTestResult.environment(
            id: 'home',
            kind: EnvironmentKind.blocked,
            required: true,
            duration: Duration.zero,
            reason: 'preflight blocked: permissions',
          ),
        ],
      ));

      for (final forbidden in const [
        'RZ8T11QETWM',
        'SSID',
        'BSSID',
        'b4:a7:c6',
        '192.168.',
      ]) {
        expect(html, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('and no seeded secret reaches it either', () {
      final text = jsonEncode(report().toJson());

      for (final entry in seeds.entries) {
        expect(text, isNot(contains(entry.value)), reason: entry.key);
      }
      for (final name in const [
        'FIGMA_TOKEN',
        'GROQ_API_KEY',
        'MYTEST_AUTH_PIN',
        'MYTEST_AUTH_MOBILE',
      ]) {
        expect(text, isNot(contains(name)), reason: name);
      }
    });

    test('the authentication check names no storage key and no credential',
        () {
      // Reading an application's own auth storage is possible on a
      // debuggable build and is deliberately not done: it would prove
      // only that something had been written. Nothing here may suggest
      // otherwise.
      final text = jsonEncode(report().toJson()).toLowerCase();

      for (final forbidden in const [
        'is_logged_in',
        'sharedpreferences',
        'run-as',
        'flutter.guest_token',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}
