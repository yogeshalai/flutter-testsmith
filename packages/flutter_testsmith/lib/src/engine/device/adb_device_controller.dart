import 'dart:io';
import 'dart:typed_data';

import '../secrets/secret_ref.dart';
import 'adb_location.dart';
import 'coordinates.dart';
import 'device_controller.dart';
import 'process_runner.dart';

/// Drives an Android device or emulator through adb.
///
/// Input goes through the real OS input stack rather than being synthesised
/// inside the Flutter binding, so a tap that a system dialog or overlay
/// would swallow is swallowed here too - which is the class of bug an
/// end-to-end test exists to catch. See ADR-0006.
///
/// This class speaks only physical pixels. Resolving an element id to a
/// point is the engine's job, above this layer.
class AdbDeviceController implements DeviceController {
  /// [adbExecutable] defaults to whatever [resolveAdb] locates, so every
  /// production caller gets the same adb without threading one through
  /// fourteen construction sites. A test that names one still wins: the
  /// resolver is consulted only when nothing was passed.
  ///
  /// Without a [processRunner] each command is bounded by what it does
  /// (see [commandTimeout]); a runner passed in is used as given.
  AdbDeviceController({
    required this.serial,
    ProcessRunner? processRunner,
    String? adbExecutable,
  })  : _runner = processRunner,
        adbExecutable = adbExecutable ?? resolveAdb().executableOrBareName;

  final String serial;
  final String adbExecutable;
  final ProcessRunner? _runner;

  /// How long an adb command that the device answers at once is given.
  ///
  /// Every adb call was unbounded, so a wedged adb server or a handset in
  /// a bad USB state hung whatever command asked it. These commands are
  /// queries and single input events, normally answered in well under a
  /// second - `dumpsys package` and `pm clear` in a few - and the first
  /// `adb devices` of a session starts the server in a few more. Thirty
  /// is meant as many times any of them, not as a measured ceiling, and
  /// is short enough to be an answer.
  static const Duration commandTimeout = Duration(seconds: 30);

  /// A screenshot moves a full-screen PNG over USB, which on a slow
  /// device and a slow port takes longer than a query.
  static const Duration screenshotTimeout = Duration(seconds: 60);

  /// What a failure message calls the executable.
  ///
  /// The file name, never the directory it was found in. [adbExecutable]
  /// is now an absolute path on most machines, and this string is copied
  /// into `StepOutcome.detail` and from there into `result.json` and
  /// `report.html` - where `C:\Users\<somebody>\AppData\Local\Android\Sdk`
  /// would be a fact about a workstation in a committed artefact. Reports
  /// carry nothing about the machine; `testsmith doctor` is where the full
  /// path is printed, to a console.
  String get _displayName {
    final cut = adbExecutable.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? adbExecutable : adbExecutable.substring(cut + 1);
  }

  /// Runs an adb command, and controls what a failure is allowed to say.
  ///
  /// [display] replaces the arguments in the exception's command string,
  /// and [scrub] removes literals from the device's own stderr. Both
  /// exist for exactly one caller - [inputSecret] - because the exception
  /// message is the one place a typed credential would otherwise
  /// surface: it is copied into `StepOutcome.detail`, and from there into
  /// `result.json`, `report.html` and the console.
  Future<ProcessResultData> _adb(
    List<String> arguments, {
    List<String>? display,
    Iterable<String> scrub = const [],
    Duration bound = commandTimeout,
  }) async {
    final full = ['-s', serial, ...arguments];

    final ProcessResultData result;
    try {
      result = await (_runner ?? SystemProcessRunner(timeout: bound))
          .run(adbExecutable, full);
    } on ProcessTimeoutException catch (error) {
      // Shown under the same rule as a failure below: [display] in place
      // of the arguments, so a typed credential is never repeated.
      throw DeviceTimeoutException(
        command: '$_displayName ${['-s', serial, ...(display ?? arguments)]
            .join(' ')}',
        timeout: error.timeout,
        stopped: error.stopped,
      );
    } on ProcessException {
      // adb was never launched, so there is no exit code to report and
      // nothing the device said. Quoting the launch failure would put
      // the executable's path - absolute on most machines - into every
      // artefact this exception reaches.
      throw DeviceUnavailableException(
        tool: _displayName,
        hint: 'Install the Android platform-tools and put adb on PATH, set '
            'ANDROID_HOME to the SDK that holds them, or set MYTEST_ADB to '
            'the executable.',
      );
    }

    if (!result.succeeded) {
      final shown = ['-s', serial, ...(display ?? arguments)];
      var stderr = result.stderr;
      for (final literal in scrub) {
        if (literal.isEmpty) continue;
        stderr = stderr.replaceAll(literal, redactionMarker);
      }
      throw DeviceCommandException(
        command: '$_displayName ${shown.join(' ')}',
        exitCode: result.exitCode,
        stderr: stderr,
      );
    }
    return result;
  }

  Future<String> _shell(
    List<String> arguments, {
    Duration bound = commandTimeout,
  }) async {
    final result = await _adb(['shell', ...arguments], bound: bound);
    return result.stdout.trim();
  }

  Future<String> _getProp(String name) => _shell(['getprop', name]);

  @override
  Future<DeviceInfo> info() async {
    final model = await _getProp('ro.product.model');
    final release = await _getProp('ro.build.version.release');
    final size = await _shell(['wm', 'size']);
    final density = await _shell(['wm', 'density']);

    final sizeMatch = RegExp(r'(\d+)x(\d+)').firstMatch(size);
    final densityMatch = RegExp(r'(\d+)').firstMatch(density);

    return DeviceInfo(
      serial: serial,
      model: model,
      androidVersion: release,
      screenWidth: int.parse(sizeMatch?.group(1) ?? '0'),
      screenHeight: int.parse(sizeMatch?.group(2) ?? '0'),
      density: int.parse(densityMatch?.group(1) ?? '0'),
    );
  }

  @override
  Future<void> terminateApp(String appId) async {
    await _shell(['am', 'force-stop', appId]);
  }

  @override
  Future<Uint8List> screenshot() async {
    final result = await _adb(
      ['exec-out', 'screencap', '-p'],
      bound: screenshotTimeout,
    );
    return result.stdoutBytes ?? Uint8List(0);
  }

  @override
  Future<void> tap(PhysicalPoint point) async {
    await _shell(['input', 'tap', '${point.x}', '${point.y}']);
  }

  @override
  Future<void> clearAppState(String appId) async {
    await _shell(['pm', 'clear', appId]);
  }

  @override
  Future<void> grantPermission(String appId, String permission) async {
    await _shell(['pm', 'grant', appId, permission]);
  }

  @override
  Future<void> longPress(PhysicalPoint point, Duration hold) async {
    // adb has no long-press verb; a zero-distance swipe with a duration is
    // the standard equivalent.
    // A gesture takes as long as it was told to, so the bound is that
    // plus the time any command is given.
    await _shell(
      [
        'input',
        'swipe',
        '${point.x}',
        '${point.y}',
        '${point.x}',
        '${point.y}',
        '${hold.inMilliseconds}',
      ],
      bound: commandTimeout + hold,
    );
  }

  @override
  Future<void> swipe(
    PhysicalPoint from,
    PhysicalPoint to,
    Duration duration,
  ) async {
    await _shell(
      [
        'input',
        'swipe',
        '${from.x}',
        '${from.y}',
        '${to.x}',
        '${to.y}',
        '${duration.inMilliseconds}',
      ],
      bound: commandTimeout + duration,
    );
  }

  @override
  Future<void> inputText(String text) async {
    // `input text` treats spaces as argument separators and interprets a
    // few characters specially.
    final escaped = text.replaceAll(' ', '%s');
    await _shell(['input', 'text', escaped]);
  }

  @override
  Future<bool> isTextInputReady() async {
    final result = await _shell(['dumpsys', 'input_method']);
    // `mInputShown` is the editor-visible flag. `mIsInputViewShown` is
    // not a substitute: it stays true while the IME process is alive
    // with no field focused at all, which is exactly the state this is
    // meant to tell apart.
    final match = RegExp(r'mInputShown=(true|false)').firstMatch(result);
    return match?.group(1) == 'true';
  }

  @override
  Future<void> inputSecret(Secret secret) async {
    final value = secret.expose();
    // The same escaping as [inputText]: `input text` treats spaces as
    // argument separators.
    final escaped = value.replaceAll(' ', '%s');
    await _adb(
      ['shell', 'input', 'text', escaped],
      display: const ['shell', 'input', 'text', redactionMarker],
      // Both forms: the escaped one is what was passed, and the raw one
      // is what a shell might echo back.
      scrub: {escaped, value},
    );
  }

  @override
  Future<void> pressBack() async {
    await _shell(['input', 'keyevent', 'KEYCODE_BACK']);
  }

  @override
  Future<void> reversePort(int hostPort, int devicePort) async {
    await _adb(['reverse', 'tcp:$devicePort', 'tcp:$hostPort']);
  }

  @override
  Future<void> removeReversePort(int devicePort) async {
    await _adb(['reverse', '--remove', 'tcp:$devicePort']);
  }

  @override
  Future<void> wake() async {
    await _shell(['input', 'keyevent', 'KEYCODE_WAKEUP']);
    // Dismisses a simple swipe lock screen. A secured device still needs
    // manual unlocking, which the caller reports as a clear diagnostic.
    await _shell(['input', 'keyevent', 'KEYCODE_MENU']);
  }
}
