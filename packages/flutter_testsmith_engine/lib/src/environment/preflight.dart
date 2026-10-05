import 'package:meta/meta.dart';

import 'prerequisite.dart';

/// What preflight found out about one prerequisite.
enum PreflightOutcome {
  /// Checked, and it is there.
  satisfied('satisfied'),

  /// Checked, it is not there, and no verdict about the application can
  /// be believed until it is.
  blocked('blocked'),

  /// Not knowable before the application runs.
  ///
  /// Recorded as its own outcome rather than guessed at, for the same
  /// reason a device profile treats an unreported fact as agreement: a
  /// runner that could not read something has learned nothing about it,
  /// which is different from learning that it is wrong.
  deferred('deferred'),

  /// Worth saying, and not a reason to stop.
  notice('notice');

  const PreflightOutcome(this.wire);

  final String wire;
}

/// One environment prerequisite, and what was found.
///
/// Modelled on [DoctorCheck], with two differences that matter: every
/// check names the [PrerequisiteClass] that owns it, and there is a
/// fourth outcome for facts that cannot be read yet.
@immutable
class PreflightCheck {
  const PreflightCheck._(
    this.name,
    this.outcome, {
    required this.klass,
    this.detail = '',
    this.remedy = '',
  });

  const PreflightCheck.satisfied(
    String name, {
    required PrerequisiteClass klass,
    String detail = '',
  }) : this._(name, PreflightOutcome.satisfied, klass: klass, detail: detail);

  /// A blocker must carry a [remedy].
  ///
  /// Required by the signature rather than by a convention: a preflight
  /// that reports "no network interface" without saying what to do about
  /// it is only a slower error message.
  const PreflightCheck.blocked(
    String name, {
    required PrerequisiteClass klass,
    required String remedy,
    String detail = '',
  }) : this._(
          name,
          PreflightOutcome.blocked,
          klass: klass,
          detail: detail,
          remedy: remedy,
        );

  const PreflightCheck.deferred(
    String name, {
    required PrerequisiteClass klass,
    String detail = '',
  }) : this._(name, PreflightOutcome.deferred, klass: klass, detail: detail);

  const PreflightCheck.notice(
    String name, {
    required PrerequisiteClass klass,
    String detail = '',
  }) : this._(name, PreflightOutcome.notice, klass: klass, detail: detail);

  final String name;
  final PrerequisiteClass klass;
  final PreflightOutcome outcome;

  /// What was found.
  ///
  /// Never a secret, and never a fact about the machine: no serial, no
  /// SSID, no MAC, no address, no credential. The connectivity probe in
  /// particular reads a source that prints all four, and filters them
  /// out on the device rather than here. Held to by a redaction test.
  final String detail;

  /// What to do about it. Empty unless this check is blocking.
  final String remedy;

  /// Only a blocker stops work.
  ///
  /// A notice is information and a deferral is an admission; treating
  /// either as a failure trains people to ignore all three.
  bool get isBlocking => outcome == PreflightOutcome.blocked;

  Map<String, Object?> toJson() => {
        'name': name,
        'class': klass.wire,
        'outcome': outcome.wire,
        'detail': detail,
        if (remedy.isNotEmpty) 'remedy': remedy,
      };
}

/// Everything preflight looked at, before any product test ran.
@immutable
class PreflightReport {
  const PreflightReport(this.checks);

  final List<PreflightCheck> checks;

  List<PreflightCheck> get blockers =>
      [for (final check in checks) if (check.isBlocking) check];

  bool get isBlocked => blockers.isNotEmpty;

  /// 2 when blocked, which is the code E-03 already uses for "something
  /// is wrong with the run".
  ///
  /// Deliberately not a code of its own. A blocked environment *is* that
  /// case, and inventing a fourth exit code would make every existing CI
  /// configuration wrong about a situation it already handled.
  int get exitCode => isBlocked ? 2 : 0;

  int countOf(PreflightOutcome outcome) =>
      checks.where((check) => check.outcome == outcome).length;

  Map<String, Object?> toJson() => {
        'blocked': isBlocked,
        'checks': [for (final check in checks) check.toJson()],
      };
}
