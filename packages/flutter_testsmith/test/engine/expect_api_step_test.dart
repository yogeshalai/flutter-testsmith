import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// Reading `expectApi:` out of a flow file.
///
/// Every malformed spelling below is a **parse error**, raised before
/// anything is launched. A step that quietly asserts nothing is the
/// worst outcome available here: the run reports green having checked
/// the API in name only, which is the same class of problem as the
/// `api:` key that was parsed and then ignored for six phases (E-10).

TestFlow parse(String steps) => TestFlow.parse(
      'appId: a\nflow: f\nsteps:\n$steps',
      source: 'test',
    );

ExpectApiStep only(String steps) =>
    parse(steps).steps.whereType<ExpectApiStep>().single;

void main() {
  group('expectApi', () {
    test('reads an endpoint and a status', () {
      final step = only('''  - expectApi:
      endpoint: GET /api/dashboard/summary
      status: 200
''');

      expect(step.endpoint.method, 'GET');
      expect(step.endpoint.path, '/api/dashboard/summary');
      expect(step.status, 200);
      expect(step.expectations, isEmpty);
      expect(step.occurrence, ResponseOccurrence.only);
    });

    test('needs an endpoint', () {
      expect(
        () => parse('  - expectApi:\n      status: 200\n'),
        throwsA(
          isA<FlowFormatException>().having(
            (e) => e.message,
            'message',
            contains('endpoint'),
          ),
        ),
      );
    });

    test('needs a status, because asserting only that a call happened '
        'would pass against a 500', () {
      expect(
        () => parse('  - expectApi:\n      endpoint: GET /a\n'),
        throwsA(
          isA<FlowFormatException>().having(
            (e) => e.message,
            'message',
            contains('status'),
          ),
        ),
      );
    });

    test('refuses an endpoint that is not METHOD /path', () {
      for (final bad in const ['/api/thing', 'GET', 'get api/thing']) {
        expect(
          () => parse('  - expectApi:\n      endpoint: $bad\n      status: 200\n'),
          throwsA(isA<FlowFormatException>()),
          reason: bad,
        );
      }
    });

    test('reads occurrence, and refuses one it does not know', () {
      expect(
        only('''  - expectApi:
      endpoint: GET /a
      status: 200
      occurrence: last
''').occurrence,
        ResponseOccurrence.last,
      );

      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      occurrence: whichever
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('reads a list of field expectations', () {
      final step = only('''  - expectApi:
      endpoint: GET /api/dashboard/summary
      status: 200
      expect:
        - path: outletsNearYou.outletsNearYouData
          count: 3
        - path: outletsNearYou.outletsNearYouData.0.businessName
          equals: Example Restaurant
        - path: token
          present: true
''');

      expect(step.expectations, hasLength(3));
      expect(step.expectations[0].count, 3);
      expect(step.expectations[1].equals, 'Example Restaurant');
      expect(step.expectations[2].present, isTrue);
    });

    test('an expectation needs a path', () {
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - equals: 3
'''),
        throwsA(
          isA<FlowFormatException>()
              .having((e) => e.message, 'message', contains('path')),
        ),
      );
    });

    test('an expectation that asserts nothing is refused', () {
      // `- path: token` alone reads as a check and is not one.
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - path: token
'''),
        throwsA(
          isA<FlowFormatException>().having(
            (e) => e.message,
            'message',
            contains('equals'),
          ),
        ),
      );
    });

    test('an expectation that asserts two things at once is refused', () {
      // Which one wins has no defensible answer, and the pair almost
      // always means the author changed their mind halfway.
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - path: token
          equals: x
          present: true
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('a count that is not a whole number is refused', () {
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - path: items
          count: -1
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('an unknown key inside an expectation is refused', () {
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - path: token
          contains: x
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('an unknown key on the step itself is refused', () {
      expect(
        () => parse('''  - expectApi:
      endpoint: GET /a
      status: 200
      body: anything
'''),
        throwsA(isA<FlowFormatException>()),
      );
    });

    test('equals keeps the type YAML gave it', () {
      // `equals: 3` must compare against the number 3, not "3". The
      // opposite would make every numeric assertion fail against a
      // correct response.
      final step = only('''  - expectApi:
      endpoint: GET /a
      status: 200
      expect:
        - path: total
          equals: 3
''');

      expect(step.expectations.single.equals, 3);
    });

    test('has a default timeout and accepts an explicit one', () {
      expect(
        only('  - expectApi:\n      endpoint: GET /a\n      status: 200\n')
            .timeout
            .inMilliseconds,
        greaterThan(0),
      );
      expect(
        only('''  - expectApi:
      endpoint: GET /a
      status: 200
      timeoutMs: 25000
''').timeout,
        const Duration(milliseconds: 25000),
      );
    });

    test('describes itself for the report', () {
      expect(
        only('''  - expectApi:
      endpoint: GET /api/dashboard/summary
      status: 200
      expect:
        - path: token
          present: true
''').describe(),
        'expect GET /api/dashboard/summary to have answered '
        '200, 1 field',
      );
    });
  });
}
