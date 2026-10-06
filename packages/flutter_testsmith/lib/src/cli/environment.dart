import 'dart:io';

import 'package:flutter_testsmith/engine.dart';

/// Runs the environment checks behind `testsmith doctor`.
///
/// The checks themselves - what counts as pass, warn or fail, and what the
/// remedy is - live in the engine (`lib/src/engine`) and are unit tested.
/// This file only gathers the facts from the host.
class EnvironmentProbe {
  const EnvironmentProbe({this.runner = const SystemProcessRunner()});

  final ProcessRunner runner;

  Future<DoctorReport> run() async {
    return DoctorReport([
      await _flutterCheck(),
      await _versionCheck(
        name: 'Dart',
        executable: 'dart',
        arguments: const ['--version'],
        remedy: 'Dart ships with Flutter; ensure the Flutter SDK is on PATH',
      ),
      await _adbCheck(),
      await _devicesCheck(),
    ]);
  }

  /// Flutter, and **which** flutter.
  ///
  /// Reported the way adb is, and for the same reason: a version with no
  /// file beside it is a version for an unknown Flutter on a machine that
  /// has more than one SDK. The source is always PATH - that is the whole
  /// policy - but saying so is what makes the executable meaningful
  /// rather than incidental.
  Future<DoctorCheck> _flutterCheck() async {
    const remedy = 'Install Flutter and put it on PATH: https://flutter.dev';

    final located = resolveFlutter();
    if (!located.isFound) {
      return DoctorCheck.fail(
        'Flutter',
        detail: located.problem!,
        remedy: located.hint.isEmpty ? remedy : located.hint,
      );
    }

    // Located and unusable is its own answer, exactly as it is for adb:
    // the file is where PATH said, and it will not run.
    final where = '${located.source!.label}: ${located.executable}';
    final ProcessResultData result;
    try {
      result = await runner.run(located.executable!, const ['--version']);
    } on ProcessException catch (error) {
      return DoctorCheck.fail(
        'Flutter',
        detail: 'found at $where, but it would not run: ${error.message}',
        remedy: remedy,
      );
    }
    if (!result.succeeded) {
      return DoctorCheck.fail(
        'Flutter',
        detail: 'found at $where, and it exited with ${result.exitCode}',
        remedy: remedy,
      );
    }

    return DoctorCheck.pass(
      'Flutter',
      detail: '${_firstLine(result.stdout)}  ($where)',
    );
  }

  /// adb, and **which** adb.
  ///
  /// Reported rather than merely found, because the commonest way for
  /// this to be wrong is for it to be right about a different binary: an
  /// older platform-tools on PATH beside the SDK's own. Two adb versions
  /// on one machine run two servers, and the one that answers is whichever
  /// started first - so "adb: ok" alone is not enough to know what ran.
  Future<DoctorCheck> _adbCheck() async {
    const remedy = 'Install Android platform-tools, set ANDROID_HOME to the '
        'SDK, or set MYTEST_ADB to the adb executable';

    final located = resolveAdb();
    if (!located.isFound) {
      return DoctorCheck.fail(
        'adb',
        detail: located.problem!,
        remedy: located.hint.isEmpty ? remedy : located.hint,
      );
    }

    // Located and unusable is its own answer. Reported through the
    // generic "not found on PATH" it named the wrong problem entirely:
    // the file is exactly where it was configured to be, and will not
    // run.
    final where = '${located.source!.label}: ${located.executable}';
    final ProcessResultData result;
    try {
      result = await runner.run(located.executable!, const ['version']);
    } on ProcessException catch (error) {
      return DoctorCheck.fail(
        'adb',
        detail: 'found at $where, but it would not run: ${error.message}',
        remedy: remedy,
      );
    }
    if (!result.succeeded) {
      return DoctorCheck.fail(
        'adb',
        detail: 'found at $where, and it exited with ${result.exitCode}',
        remedy: remedy,
      );
    }

    // A configured location that held nothing is worth saying even when
    // the run carried on without it.
    final note =
        located.skipped.isEmpty ? '' : '; ${located.skipped.join('; ')}';
    return DoctorCheck.pass(
      'adb',
      detail: '${_firstLine(result.stdout)}  ($where)$note',
    );
  }

  Future<DoctorCheck> _versionCheck({
    required String name,
    required String executable,
    required List<String> arguments,
    required String remedy,
  }) async {
    try {
      final result = await runner.run(executable, arguments);
      if (!result.succeeded) {
        return DoctorCheck.fail(
          name,
          detail: 'exited with ${result.exitCode}',
          remedy: remedy,
        );
      }
      return DoctorCheck.pass(name, detail: _firstLine(result.stdout));
    } on ProcessException {
      return DoctorCheck.fail(name, detail: 'not found on PATH', remedy: remedy);
    }
  }

  Future<DoctorCheck> _devicesCheck() async {
    final located = resolveAdb();
    if (located.namedButAbsent) {
      // The row above has already said what is wrong with MYTEST_ADB.
      // What this one must not do is go and ask a different adb and
      // report a handset, so that one report says both "there is no adb"
      // and "here is a device".
      return DoctorCheck.fail(
        'Android device',
        detail: 'not asked: adb was not located',
        remedy: located.hint,
      );
    }

    try {
      final result = await runner
          .run(located.executableOrBareName, const ['devices', '-l']);
      final devices = parseAdbDevices(result.stdout);

      if (devices.isEmpty) {
        // A warning, not a failure: doctor is still useful with no device
        // attached, and treating it as an error would train people to
        // ignore real failures.
        return const DoctorCheck.warn(
          'Android device',
          detail: 'none attached',
          remedy: 'Attach a device with USB debugging enabled, or start an '
              'emulator, then re-run',
        );
      }

      return DoctorCheck.pass(
        'Android device',
        detail: devices.map((d) => d.toString()).join(', '),
      );
    } on ProcessException {
      return const DoctorCheck.fail(
        'Android device',
        detail: 'adb unavailable',
        remedy: 'Install Android platform-tools and add them to PATH',
      );
    }
  }

  static String _firstLine(String text) {
    final lines = text.trim().split('\n');
    return lines.isEmpty ? '' : lines.first.trim();
  }
}
