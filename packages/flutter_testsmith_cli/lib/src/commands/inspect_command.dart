import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import '../app_session.dart';
import '../device_selection.dart';
import '../output.dart';
import '../output_path.dart';
import '../project_root.dart';
import '../tree_renderer.dart';

/// Dumps the semantic UI tree of the running screen.
class InspectCommand extends Command<int> {
  InspectCommand() {
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
      ..addOption('device', abbr: 'd', help: 'Device serial.')
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
        'tap',
        help: 'Tap this test id before capturing, to inspect a later screen.',
      )
      ..addOption(
        'json',
        help: 'Also write the snapshot to this file. Relative to the '
            'application; an absolute path is taken as written.',
      );
  }

  @override
  String get name => 'inspect';

  @override
  String get description =>
      'Capture and print the semantic UI tree of the current screen.';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    // It takes no positional argument, and one given was dropped: most
    // often a test id meant for `--tap`, which captured the first screen
    // instead. 64, as an option it does not know already is.
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

    // The same identity rule `testsmith smoke` applies, from the same
    // function. Two commands that launched and force-stopped applications
    // under different rules would be two answers to one question.
    final appId = requiredAppId(args.option('app-id'), output);
    if (appId == null) return 1;

    final serial = args.option('device') ?? await selectSoleDevice(output);
    if (serial == null) return 1;

    // `--device` skips selection, and skipped verification with it. The
    // first adb command of the run was then the launch's own, issued
    // against a serial nobody had checked: `AdbDeviceController` raises
    // `DeviceCommandException` there, which is not the
    // `DeviceUnavailableException` the guard below catches and is not
    // caught anywhere above it either, so a stale `--device` ended the
    // process at 255 with a stack trace and an absolute source path.
    //
    // `run` has always asked this here, from this function, and
    // `verifyDevice` was written for exactly this case - "a mistyped
    // serial surfaces as a stack trace rather than as the simple mistake
    // it is". Asking it the same way is what keeps the two commands to
    // one sentence.
    if (!await verifyDevice(serial, output)) return 1;

    // The other half of the same omission. `AppSession.launch` asks for
    // `executableOrBareName`, whose bare-name fallback is deliberate -
    // "a machine that works today keeps working" - and nobody here asked
    // whether anything had been located, so a machine without Flutter
    // reached `startProcess` and ended at 255 with a `ProcessException`,
    // a stack trace and an absolute source path.
    //
    // Every other command that starts an application already asks:
    // `preflight`, `suite run` and `auth setup` hand
    // `resolveFlutter().isFound` to `checkApplicationBuild`, and
    // `doctor` renders these same two strings in its Flutter row. Asked
    // after the device, because a mistyped serial is a statement about
    // this machine's handset and answering it with "install Flutter"
    // would name the wrong problem.
    final flutter = resolveFlutter();
    if (!flutter.isFound) {
      output
        ..line(output.red(flutter.problem!))
        ..line(output.dim('  ${flutter.hint}'));
      return 1;
    }

    // Outside the try below, which starts once there is a session to
    // dispose of.
    final AppSession session;
    try {
      session = await AppSession.launch(
        target: args.option('target'),
        flavor: args.option('flavor'),
        projectDirectory: projectDirectory,
        deviceSerial: serial,
        appId: appId,
        log: output.line,
      );
    } on DeviceUnavailableException catch (error) {
      output..line()..line(output.red('$error'));
      return 1;
    } catch (error) {
      // Every other way a launch fails, said as `run` says it. Only the
      // exception above was caught, so the rest reached
      // `bin/testsmith.dart` - which catches UsageException and nothing
      // else - and ended at 255 with a stack trace. The commonest is an
      // `--app-id` the device does not have, which is confirmed after
      // the app starts. `run`, `smoke` and `auth setup` all catch here.
      // Nothing to dispose: a launch that throws has torn down what it
      // set up.
      output
        ..line()
        ..line(output.red('Could not start the app: $error'));
      return 1;
    }

    try {
      // Let the first frame settle; a tree captured mid-build is missing
      // whatever has not been laid out.
      await Future<void>.delayed(const Duration(seconds: 3));

      final tapId = args.option('tap');
      if (tapId != null) {
        output.line('› tapping "$tapId" first');
        // 30s, not the 10s default. The element being waited for is
        // often on a screen the app has not reached yet: measured on a
        // real application whose splash does three network calls before
        // navigating, 10s expired while it was still on the splash and
        // `inspect` reported "no element ... the captured tree has no
        // test ids at all", which describes the splash perfectly and
        // explains nothing.
        await session.tapById(tapId, timeout: const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      final snapshot = await session.captureUiTree();

      output.line();
      TreeRenderer(output).render(snapshot);

      // What is moving, named. Discovering this is the first step of
      // declaring a quiescence exception, and before it existed the
      // only available reading was a number. See STOP-2.
      final settle = await session.readSettle();
      if (settle.animations.isNotEmpty || settle.transientCallbacks > 0) {
        output..line()..line(output.bold('Animations running'));
        for (final animation in settle.animations) {
          final id = animation.elementId;
          output.line('  ${animation.owner}'
              '${id == null ? output.red('  (no semantic id - it cannot be '
                  'declared until it has one)') : '  #$id'}'
              '${animation.routeIndex == null ? '' : '  route ${animation.routeIndex}'}'
              '${animation.bounds == null ? '' : '  at ${animation.bounds!.x.round()},${animation.bounds!.y.round()} ${animation.bounds!.width.round()}x${animation.bounds!.height.round()}'}');
        }
        final unnamed = settle.transientCallbacks - settle.animations.length;
        if (unnamed > 0) {
          output.line(output.red('  $unnamed more that could not be named'));
        }
      }

      final jsonPath = args.option('json');
      if (jsonPath != null) {
        final file = resolveOutputFile(projectDirectory, jsonPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
        );
        output.line('  written to ${file.path}');
      }

      // An ambiguous id makes every later assertion about it meaningless,
      // so it fails the command rather than merely being noted.
      return snapshot.hasAmbiguousIds ? 1 : 0;
    } on ElementNotFoundException catch (error) {
      output..line()..line(output.red(error.toString()));
      return 1;
    } catch (error) {
      output..line()..line(output.red('inspect failed: $error'));
      return 1;
    } finally {
      await session.dispose();
    }
  }
}
