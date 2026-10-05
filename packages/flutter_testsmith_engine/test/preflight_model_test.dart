// The shape of an environment finding.
//
// E-04's whole claim rests on a distinction: a result may say something
// about the application, or it may say that the application could not be
// examined. This file covers the second kind - what a check is allowed to
// record, what obliges a remedy, and what a report made of them says.
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  group('PreflightCheck', () {
    test('a blocked check carries a remedy', () {
      const check = PreflightCheck.blocked(
        'permissions',
        klass: PrerequisiteClass.devicePrerequisite,
        detail: 'ACCESS_FINE_LOCATION denied',
        remedy: 'adb shell pm grant com.example.app '
            'android.permission.ACCESS_FINE_LOCATION',
      );

      expect(check.outcome, PreflightOutcome.blocked);
      expect(check.isBlocking, isTrue);
      expect(check.remedy, isNotEmpty);
    });

    test('deferred is not blocking: a fact nobody could read yet is not a '
        'fact that disagrees', () {
      const check = PreflightCheck.deferred(
        'authentication',
        klass: PrerequisiteClass.humanAction,
        detail: 'resolved at first launch',
      );

      expect(check.outcome, PreflightOutcome.deferred);
      expect(check.isBlocking, isFalse);
    });

    test('a notice is not blocking', () {
      const check = PreflightCheck.notice(
        'baselines',
        klass: PrerequisiteClass.runnerControlled,
        detail: '1 screen has none; it will be recorded and skipped',
      );

      expect(check.isBlocking, isFalse);
    });

    test('satisfied is not blocking', () {
      const check = PreflightCheck.satisfied(
        'device',
        klass: PrerequisiteClass.devicePrerequisite,
        detail: 'SM-M127G',
      );

      expect(check.isBlocking, isFalse);
    });
  });

  group('PreflightReport', () {
    test('is blocked when any check is, and names which', () {
      const report = PreflightReport([
        PreflightCheck.satisfied(
          'device',
          klass: PrerequisiteClass.devicePrerequisite,
          detail: 'SM-M127G',
        ),
        PreflightCheck.blocked(
          'network interface',
          klass: PrerequisiteClass.devicePrerequisite,
          detail: 'no active default network',
          remedy: 'Turn on Wi-Fi. No backend has to be reachable.',
        ),
      ]);

      expect(report.isBlocked, isTrue);
      expect(report.blockers.map((c) => c.name), ['network interface']);
    });

    test('a blocked report exits 2 - the code E-03 already uses for "the run '
        'did not answer the question"', () {
      const report = PreflightReport([
        PreflightCheck.blocked(
          'mock API',
          klass: PrerequisiteClass.runnerControlled,
          detail: 'port 8080 is in use',
          remedy: 'Free the port, or change mockApi.port.',
        ),
      ]);

      expect(report.exitCode, 2);
    });

    test('a report with only notices and deferrals exits 0', () {
      const report = PreflightReport([
        PreflightCheck.notice(
          'baselines',
          klass: PrerequisiteClass.runnerControlled,
          detail: '1 without a baseline',
        ),
        PreflightCheck.deferred(
          'authentication',
          klass: PrerequisiteClass.humanAction,
          detail: 'required by home',
        ),
      ]);

      expect(report.isBlocked, isFalse);
      expect(report.exitCode, 0);
    });

    test('counts each outcome', () {
      const report = PreflightReport([
        PreflightCheck.satisfied('a',
            klass: PrerequisiteClass.runnerControlled),
        PreflightCheck.satisfied('b',
            klass: PrerequisiteClass.runnerControlled),
        PreflightCheck.notice('c', klass: PrerequisiteClass.runnerControlled),
      ]);

      expect(report.countOf(PreflightOutcome.satisfied), 2);
      expect(report.countOf(PreflightOutcome.notice), 1);
      expect(report.countOf(PreflightOutcome.blocked), 0);
    });

    test('serialises exactly name, class, outcome and detail - and no more', () {
      const report = PreflightReport([
        PreflightCheck.satisfied(
          'device',
          klass: PrerequisiteClass.devicePrerequisite,
          detail: 'SM-M127G',
        ),
      ]);

      final json = report.toJson();
      expect(json['blocked'], isFalse);

      final checks = json['checks']! as List<Object?>;
      final first = checks.single! as Map<String, Object?>;
      expect(first.keys.toSet(), {'name', 'class', 'outcome', 'detail'});
      expect(first['class'], 'devicePrerequisite');
      expect(first['outcome'], 'satisfied');
      expect(first['detail'], 'SM-M127G');
    });

    test('a blocked check also serialises its remedy', () {
      const report = PreflightReport([
        PreflightCheck.blocked(
          'mock API',
          klass: PrerequisiteClass.runnerControlled,
          detail: 'port 8080 is in use',
          remedy: 'Free the port, or change mockApi.port.',
        ),
      ]);

      final checks = report.toJson()['checks']! as List<Object?>;
      final first = checks.single! as Map<String, Object?>;
      expect(first['remedy'], 'Free the port, or change mockApi.port.');
    });
  });

  group('PrerequisiteClass', () {
    test('every class has a distinct wire name', () {
      final wires = PrerequisiteClass.values.map((c) => c.wire).toSet();
      expect(wires, hasLength(PrerequisiteClass.values.length));
    });
  });
}
