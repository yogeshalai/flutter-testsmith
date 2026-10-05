import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../device_selection.dart';
import '../mock_api_server.dart';
import '../output.dart';
import '../output_path.dart';
import '../project_root.dart';
import '../smoke.dart';
import '../tree_renderer.dart';

/// Exercises the whole Phase 1 channel against a real device.
class SmokeCommand extends Command<int> {
  SmokeCommand() {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help: 'Entry point to launch, when the app is not lib/main.dart.',
      )
      ..addOption(
        'flavor',
        help: 'Build flavor, for an app that has them.',
      )
      ..addOption(
        'app',
        help: 'Directory of the Flutter application to launch. Defaults to '
            'the nearest directory at or above this one with a pubspec.yaml.',
      )
      ..addOption(
        'app-id',
        help: 'Required. The Android package this drives and force-stops '
            'during teardown. A wrong value fails silently - `am '
            'force-stop` succeeds for a package that is not installed - '
            'and leaves the app running, which then breaks the next run, '
            'so it is checked against the device before anything is '
            'stopped.',
      )
      ..addOption(
        'device',
        abbr: 'd',
        help: 'Device serial. Defaults to the only attached device.',
      )
      ..addOption(
        'out',
        help: 'Where to write the screenshots it captures. Relative to '
            'the application; an absolute path is taken as written.',
        defaultsTo: 'out',
      )
      ..addOption(
        'tap-id',
        help: 'Semantic id to tap, resolved from the captured UI tree.',
      )
      ..addOption(
        'tap',
        help: 'Physical "x,y" to tap. Use --tap-id instead where the '
            'element carries a test id; coordinates are for screens that '
            'do not.',
      )
      ..addFlag(
        'tree',
        help: 'Print the captured UI tree.',
      )
      ..addOption(
        'mock-api',
        help: 'Serve the fixture API on this host port and map it into '
            'the device with adb reverse.',
      )
      ..addOption(
        'assert-absent',
        help: 'Fail if this string appears anywhere in the emitted '
            'events. Used to prove redaction on real traffic.',
      );
  }

  @override
  String get name => 'smoke';

  @override
  String get description =>
      'Launch the app, attach over the VM Service, and verify the channel.';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    // It takes no positional argument, and one given was dropped - a
    // value handed to a flag, as in `--tree false`, which left the flag
    // on. 64, as an option it does not know already is.
    if (args.rest.isNotEmpty) {
      usageException('Unexpected argument: ${args.rest.join(' ')}');
    }

    final root = resolveProjectRoot(args.option('app'));
    if (!root.isFound) {
      output
        ..line(output.red(root.problem!))
        ..line(output.dim('  ${root.hint}'));
      return 1;
    }
    final projectDirectory = root.directory!;

    // Before the device is touched, because a missing package id is a
    // sentence to read rather than something to discover eight minutes
    // into a build.
    final appId = requiredAppId(args.option('app-id'), output);
    if (appId == null) return 1;

    // `run`'s rule, from the same function, and for the same reason
    // before the device: a mistyped port used to mean no fixture server
    // and a smoke run against the real API. 1, as a bad `--tap` is.
    final int? mockApiPort;
    try {
      mockApiPort = parseMockApiPort(args.option('mock-api'));
    } on FormatException catch (error) {
      output.line(output.red(error.message));
      return 1;
    }

    // The other option that is a value to parse, read with it. It came
    // after the device gate, so a mistyped point waited on adb, and on a
    // machine without adb was never mentioned at all.
    final tap = _parseTap(args.option('tap'), output);
    if (tap == null && args.option('tap') != null) return 1;

    // Read, checked and resolved before the device, where `run` does it
    // and in its words: a scenario file is a fact about the project, and
    // nothing needs to be attached to discover it. Inside the runner it
    // came after the device and Flutter checks, so a scenario that would
    // not parse was hidden behind whatever the machine lacked, then
    // reported as "Smoke run failed". Only for a run that serves one.
    ApiScenario? scenario;
    if (mockApiPort != null) {
      scenario = _scenarioToServe(projectDirectory, output);
      if (scenario == null) return 1;
    }

    final serial = args.option('device') ?? await selectSoleDevice(output);
    if (serial == null) return 1;
    // A named device is checked before anything is launched, as `run`
    // and `inspect` check it. Without this a mistyped serial, or no adb
    // at all, was met by the runner's first adb call: "waking device"
    // for a device nobody had looked for, then a raw
    // DeviceCommandException, or the controller's mid-run "could not be
    // started" where every other command says "could not be found".
    if (!await verifyDevice(serial, output)) return 1;

    // Asked before the runner, as `inspect` asks it: without this, a
    // machine with no Flutter had its handset woken and then heard a raw
    // ProcessException quoting the Dart runtime's own source file, where
    // `inspect`, `doctor`, `preflight` and `suite run` all give the
    // resolver's sentence and say what to install. After the device and
    // the options, because a mistyped serial or tap is a statement about
    // the invocation, and answering it with "install Flutter" would name
    // the wrong problem. No working machine is refused: the resolver
    // accepts the same `.bat`/`.cmd`/`.exe` a bare launch would run.
    final flutter = resolveFlutter();
    if (!flutter.isFound) {
      output
        ..line(output.red(flutter.problem!))
        ..line(output.dim('  ${flutter.hint}'));
      return 1;
    }

    final runner = SmokeRunner(
      projectDirectory: projectDirectory,
      outputDirectory:
          resolveOutputDirectory(projectDirectory, args.option('out')!),
      deviceSerial: serial,
      tapId: args.option('tap-id'),
      tapPoint: tap,
      appId: appId,
      target: argResults!.option('target'),
      flavor: argResults!.option('flavor'),
      mockApiPort: mockApiPort,
      mockApiScenario: scenario,
      stdout: output.line,
    );

    final SmokeResult result;
    try {
      result = await runner.run();
    } on FixtureServerException catch (error) {
      // The sentence `run` and `suite run` use, so one failure reads the
      // same way whichever command met it.
      output
        ..line()
        ..line(output.red('The fixture server could not be started:'))
        ..line('  ${error.reason}');
      return 1;
    } on SdkNotFoundException catch (error) {
      output
        ..line()
        ..line(output.red('The app is running but the SDK is not armed.'))
        ..line(error.toString());
      return 1;
    } catch (error) {
      output
        ..line()
        ..line(output.red('Smoke run failed: $error'));
      return 1;
    }

    return _report(
      output,
      result,
      printTree: args.flag('tree'),
      mustBeAbsent: args.option('assert-absent'),
    );
  }

  int _report(
    Output output,
    SmokeResult result, {
    bool printTree = false,
    String? mustBeAbsent,
  }) {
    final handshake = result.handshake;
    final manager = result.manager;

    output
      ..line()
      ..line(output.bold('Smoke result'))
      ..line()
      ..line('  session          ${handshake.sessionId}')
      ..line('  protocol         ${handshake.protocolVersion}')
      ..line('  capabilities     ${handshake.capabilities.join(', ')}')
      ..line('  app version      ${handshake.app.appVersion}')
      ..line('  build mode       ${handshake.app.buildMode.wire}')
      ..line('  dpr at attach    ${handshake.app.devicePixelRatio}'
          '${output.dim('  (may predate the first frame)')}')
      ..line('  dpr settled      '
          '${result.settledApp?.devicePixelRatio ?? 'unavailable'}')
      ..line()
      ..line('  recovered from ring buffer   ${result.recoveredCount}')
      ..line('  arrived on live stream       ${result.streamedCount}')
      ..line('  duplicates discarded         ${manager.duplicateCount}')
      ..line('  distinct events              ${manager.events.length}')
      ..line(
        '  history complete             '
        '${handshake.historyIsComplete ? 'yes' : 'no (${handshake.droppedEventCount} dropped)'}',
      )
      ..line();

    final snapshot = result.snapshot;
    if (snapshot != null) {
      output
        ..line('  ui tree nodes                ${snapshot.retainedNodeCount}')
        ..line('  elements walked              ${snapshot.totalElementsWalked}')
        ..line('  test ids found               '
            '${snapshot.root.testIds.length}')
        ..line();
    }

    if (result.tappedPoint != null) {
      output..line('  tapped                       ${result.tappedPoint}')..line();
    }

    final correlation = result.correlation;
    if (correlation != null && correlation.sessions.isNotEmpty) {
      output.line(output.bold('  API exchanges by screen'));
      for (final session in correlation.sessions) {
        output.line('    ${session.screenId}');
        if (session.exchanges.isEmpty) {
          output.line(output.dim('      (none)'));
        }
        for (final exchange in session.exchanges) {
          final outcome = exchange.response == null
              ? output.yellow('no response')
              : exchange.succeeded
                  ? output.green('${exchange.response!.statusCode}')
                  : output.red(
                      '${exchange.response!.statusCode ?? exchange.response!.error}',
                    );
          output.line('      ${exchange.request.method} '
              '${exchange.request.path}  $outcome');
        }
      }
      if (correlation.unattributed.isNotEmpty) {
        output.line(output.yellow(
          '    unattributed: ${correlation.unattributed.length}',
        ));
      }
      output.line();
    }

    output.line(output.bold('  Event stream (chronological)'));

    for (final event in manager.events) {
      final screen = event.screenId == null ? '' : ' ${event.screenId}';
      output.line(
        '    ${output.dim(_time(event.timestamp))}  '
        '${event.type.wire.padRight(14)}$screen',
      );
    }

    output
      ..line()
      ..line('  screens visited  ${manager.screenHistory.join(' -> ')}')
      ..line('  current screen   ${manager.currentScreenId}')
      ..line();

    // The phase exists to prove pre-subscription recovery, so that is what
    // decides the exit code.
    final recoveredStartup = manager.events.any(
      (e) => e.type == EventType.sessionStart,
    );
    if (!recoveredStartup) {
      output.line(
        output.red('FAIL: SESSION_START was not recovered. The ring buffer '
            'did not deliver the pre-subscription history.'),
      );
      return 1;
    }

    if (result.tapError != null) {
      output.line(output.red('FAIL: the tap did not resolve.'));
      return 1;
    }

    // The Phase 3 exit criterion, checked against real traffic rather
    // than only in unit tests: a secret must appear nowhere at all.
    if (mustBeAbsent != null) {
      final haystack = jsonEncode([
        for (final event in result.manager.events) event.toJson(),
      ]);
      if (haystack.contains(mustBeAbsent)) {
        output.line(output.red(
          'FAIL: "$mustBeAbsent" leaked into the emitted events.',
        ));
        return 1;
      }
      output.line(output.green(
        'redaction verified: "$mustBeAbsent" appears nowhere in '
        '${result.manager.events.length} events',
      ));
    }

    if (printTree && result.snapshot != null) {
      output.line();
      TreeRenderer(output).render(result.snapshot!);
    }

    output.line(output.green('PASS: channel verified end to end.'));
    return 0;
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${(t.millisecond).toString().padLeft(3, '0')}';

  /// The default scenario, resolved, or null once the reason it cannot
  /// be has been said. `run`'s three refusals, in its words.
  ApiScenario? _scenarioToServe(Directory project, Output output) {
    final ScenarioLibrary library;
    try {
      library = ScenarioLibrary.load(
        Directory('${project.path}/mock_api/scenarios'),
      );
    } on ScenarioFormatException catch (error) {
      output.line(output.red('$error'));
      return null;
    }

    const name = ScenarioLibrary.defaultName;
    if (!library.contains(name)) {
      output
        ..line(output.red('No API scenario named "$name".'))
        ..line()
        ..line('Looked in ${library.directory.path}.')
        ..line('Available: '
            '${library.names.isEmpty ? '(none)' : library.names.join(', ')}');
      return null;
    }

    try {
      return library.resolve(name);
    } on ScenarioFormatException catch (error) {
      output.line(output.red('$error'));
      return null;
    }
  }

  PhysicalPoint? _parseTap(String? raw, Output output) {
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 2) {
      output.line(output.red('--tap expects "x,y", got "$raw"'));
      return null;
    }
    final x = int.tryParse(parts[0].trim());
    final y = int.tryParse(parts[1].trim());
    if (x == null || y == null) {
      output.line(output.red('--tap expects two integers, got "$raw"'));
      return null;
    }
    return PhysicalPoint(x, y);
  }

}
