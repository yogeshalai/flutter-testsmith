import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The outcome of running an external command.
@immutable
class ProcessResultData {
  const ProcessResultData({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.stdoutBytes,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// Raw stdout, for commands whose output is binary (a screenshot).
  final Uint8List? stdoutBytes;

  bool get succeeded => exitCode == 0;
}

/// Names to try when launching [executable].
///
/// On Windows many tools ship as a `.bat` shim - `flutter` is
/// `flutter.bat` - and `Process.run` will not resolve a bare name to one.
/// Without this, `testsmith doctor` reports Flutter as missing on a machine
/// where it plainly works, which is worse than not checking at all.
///
/// A name that already has an extension, or that is an explicit path, is
/// left alone: the caller was being specific and guessing would
/// second-guess them.
List<String> executableCandidates(String executable, {required bool isWindows}) {
  if (!isWindows) return [executable];

  final hasExtension = executable.contains('.');
  final isPath = executable.contains('/') || executable.contains(r'\');
  if (hasExtension || isPath) return [executable];

  return [
    executable,
    '$executable.bat',
    '$executable.cmd',
    '$executable.exe',
  ];
}

/// Runs external commands.
///
/// An interface purely so device control can be tested without a device:
/// command construction is the part worth asserting, and it is also the
/// part most likely to be wrong.
abstract interface class ProcessRunner {
  Future<ProcessResultData> run(String executable, List<String> arguments);
}

/// A command that did not finish within the time allowed it.
///
/// Its own type, and not a [ProcessException]: that means the command
/// never ran, and every caller already answers it as "install it". A
/// command that ran and never answered is a different fault - a wedged
/// adb server, a handset in a bad USB state - with a different remedy.
class ProcessTimeoutException implements Exception {
  const ProcessTimeoutException({
    required this.tool,
    required this.timeout,
    required this.stopped,
  });

  /// The file name, never the directory it was found in.
  final String tool;

  final Duration timeout;

  /// Whether the process was seen to exit after it was killed. Said
  /// rather than assumed: a kill is a request.
  final bool stopped;

  @override
  String toString() => '$tool did not finish within ${timeout.inSeconds} '
      'seconds${stopped ? ', and was stopped' : ', and could not be stopped'}.';
}

/// Ends [process] and, on Windows, everything it started.
///
/// On Windows a `.bat` or `.cmd` runs in `cmd.exe`, and the program it
/// names is that shell's child - there is no `exec` to put it in the
/// shell's place. Killing the one process leaves the real one running.
/// So the tree, through `taskkill`, and the plain kill only if that
/// could not be asked. Elsewhere the plain kill: a launcher there `exec`s.
///
/// Only for a process that has not exited: once it has, its pid may name
/// some other process, which a tree kill would end.
Future<void> killProcessTree(Process process) async {
  if (Platform.isWindows) {
    try {
      final result = await Process.run(
        'taskkill',
        ['/PID', '${process.pid}', '/T', '/F'],
      );
      if (result.exitCode == 0) return;
    } on ProcessException {
      // No taskkill on PATH: the plain kill below is all there is.
    }
  }
  process.kill(ProcessSignal.sigkill);
}

/// Runs commands for real.
///
/// With [timeout], a command that has not finished by then is ended,
/// with everything it started, and reported as a
/// [ProcessTimeoutException]. Without one it is waited on for as long as
/// it takes, as it always was - right for a first `flutter --version`,
/// which may be downloading an SDK.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner({this.timeout});

  final Duration? timeout;

  @override
  Future<ProcessResultData> run(
    String executable,
    List<String> arguments,
  ) async {
    final candidates =
        executableCandidates(executable, isWindows: Platform.isWindows);

    ProcessException? lastFailure;
    for (final candidate in candidates) {
      try {
        final bound = timeout;
        return bound == null
            ? await _runOne(candidate, arguments)
            : await _runBounded(candidate, arguments, bound);
      } on ProcessException catch (error) {
        lastFailure = error;
      }
    }
    throw lastFailure!;
  }

  Future<ProcessResultData> _runBounded(
    String executable,
    List<String> arguments,
    Duration bound,
  ) async {
    final process = await Process.start(executable, arguments);

    // Both pipes read at once, as `Process.run` reads them: a child that
    // fills one while nobody drains it blocks for ever.
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final outSubscription =
        process.stdout.listen(out.add, onDone: outDone.complete);
    final errSubscription =
        process.stderr.listen(err.add, onDone: errDone.complete);

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(bound);
    } on TimeoutException {
      await killProcessTree(process);
      final stopped = await process.exitCode
          .then((_) => true)
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
      // Not waited on: whatever is still holding the pipes would hold
      // this too.
      await outSubscription.cancel();
      await errSubscription.cancel();
      final cut = executable.lastIndexOf(RegExp(r'[/\\]'));
      throw ProcessTimeoutException(
        tool: cut < 0 ? executable : executable.substring(cut + 1),
        timeout: bound,
        stopped: stopped,
      );
    }

    // The output can still be arriving after the exit is seen. Bounded,
    // so a grandchild that kept the pipe cannot keep this.
    await Future.wait<void>([outDone.future, errDone.future])
        .timeout(const Duration(seconds: 5), onTimeout: () => const <void>[]);
    await outSubscription.cancel();
    await errSubscription.cancel();

    final outBytes = out.takeBytes();
    return ProcessResultData(
      exitCode: exitCode,
      stdout: _decode(outBytes),
      stderr: _decode(err.takeBytes()),
      stdoutBytes: outBytes,
    );
  }

  Future<ProcessResultData> _runOne(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(
      executable,
      arguments,
      stdoutEncoding: null, // keep bytes; decode below when text is wanted
      stderrEncoding: null,
    );

    final outBytes = Uint8List.fromList(result.stdout as List<int>);
    final errBytes = result.stderr as List<int>;

    return ProcessResultData(
      exitCode: result.exitCode,
      stdout: _decode(outBytes),
      stderr: _decode(errBytes),
      stdoutBytes: outBytes,
    );
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Binary output (a screenshot) is not text; callers wanting bytes
      // read stdoutBytes instead.
      return '';
    }
  }
}

/// Starts a long-running process, resolving the executable the same way
/// [SystemProcessRunner] does.
///
/// Kept beside the runner so executable resolution lives in exactly one
/// place: the Windows `.bat` problem bit once through `Process.run` and
/// again through `Process.start`, and a second copy of the rule would
/// simply wait to drift.
Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final candidates =
      executableCandidates(executable, isWindows: Platform.isWindows);

  ProcessException? lastFailure;
  for (final candidate in candidates) {
    try {
      return await Process.start(
        candidate,
        arguments,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      lastFailure = error;
    }
  }
  throw lastFailure!;
}
