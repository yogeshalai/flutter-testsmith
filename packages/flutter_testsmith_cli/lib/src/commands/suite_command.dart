import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import '../dotenv.dart';
import '../figma_source_resolver.dart';
import '../mock_api_server.dart';
import '../output.dart';
import '../output_path.dart';
import 'preflight_command.dart';
import '../preflight_runner.dart';
import '../project_config.dart';
import '../flow_runner.dart';
import '../secrets/env_secret_resolver.dart';
import '../suite_runner.dart';

/// `testsmith suite` - run several flows as one reproducible suite.
class SuiteCommand extends Command<int> {
  SuiteCommand() {
    addSubcommand(SuiteRunSubcommand());
  }

  @override
  String get name => 'suite';

  @override
  String get description => 'Run a suite of flows against one device.';
}

class SuiteRunSubcommand extends Command<int> {
  SuiteRunSubcommand() {
    argParser
      ..addOption('device', abbr: 'd', help: 'Device serial.')
      ..addOption(
        'out',
        help: 'Where to write the suite result and each test report. '
            'Relative to the application the suite names; an absolute '
            'path is taken as written.',
        defaultsTo: 'out/suite',
      )
      ..addFlag(
        'update-visual-baselines',
        help: 'Replace each compared screenshot baseline with this run.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run every flow a suite declares, in order.';

  @override
  String get invocation => 'testsmith suite run <suite.yaml>';

  /// Usage errors, matching what `testsmith run` already returns.
  static const int _usage = 64;

  /// A suite that could not be set up at all.
  ///
  /// The same code an unevaluable required test produces, because they
  /// are the same news: the run did not answer the question.
  static const int _error = 2;

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    if (args.rest.length != 1) {
      output
        ..line(output.red('Expected exactly one suite file.'))
        ..line(output.dim('Usage: $invocation'));
      return _usage;
    }

    final suiteFile = File(args.rest.single);

    // 1-4. Syntax, the flows it names, the device profile, a device.
    // Shared with `testsmith preflight`, so the two cannot drift into
    // checking different things.
    final context = await resolveSuiteContext(
      suiteFile: suiteFile,
      requestedSerial: args.option('device'),
      output: output,
    );
    if (context == null) return _error;

    final suite = context.suite;
    final projectDirectory = context.project;
    final profile = context.profile;
    // Null when no device could be chosen. Nothing below addresses one
    // until preflight has passed, and preflight cannot pass without a
    // serial - the device check blocks on exactly that - so the handset
    // is reached through `serial!` there and nowhere earlier.
    final serial = context.serial;

    // Resolved here rather than beside the suite file, because the
    // application is not known until the suite has named it. A relative
    // `--out` belongs to that application, not to wherever the caller
    // was standing when they typed it.
    final outputDirectory =
        resolveOutputDirectory(projectDirectory, args.option('out')!);
    // suite.json is written on every outcome, so an --out it can never go
    // into is refused now - the contract `run` and `auth setup` keep,
    // from the same function. Unchecked, a blocked suite printed its
    // preflight and then ended at 255 trying to write the answer.
    final outputProblem = outputDirectoryProblem(outputDirectory);
    if (outputProblem != null) {
      output
        ..line(output.red('--out cannot be used: $outputProblem'))
        ..line(output.dim(
          '  Name a directory, or remove what is in the way.',
        ));
      return _error;
    }

    output
      ..line(output.bold('${suite.name}  ${output.dim(suiteFile.path)}'))
      ..line('  device profile  ${profile.id}'
          '${profile.model == null ? '' : ' (${profile.model})'}')
      ..line('  tests           ${suite.tests.length}, '
          'onFailure: ${suite.onFailure.wire}')
      ..line();

    // 5. Everything the project can be judged on by itself, before the
    // device is touched, before preflight and before the fixture server
    // binds a port.
    //
    // The device has already been *located* by the context above, which
    // is also where the application root comes from, so this cannot run
    // any earlier without giving the suite a second answer to "where is
    // the app". What it can do is come before anything is done *to* the
    // device, reported, arranged or opened - so a project with two
    // mappings for one screen is told about the mappings rather than
    // about a handset.
    final Map<String, MappingsFile> mappings;
    try {
      mappings = await loadMappings(projectDirectory);
    } on MappingsFormatException catch (error) {
      output.line(output.red('$error'));
      return _blockedBeforePreflight(
        context: context,
        check: checkScreenConfiguration(
          duplicate: null,
          unreadable: unreadableMappingMessage(error),
        ),
        outputDirectory: outputDirectory,
        output: output,
      );
    } on DuplicateScreenException catch (error) {
      // A suite that resolved this by listing order would report a
      // different verdict on a different machine, which is the one
      // thing a suite exists not to do.
      output.line(output.red('$error'));
      return _blockedBeforePreflight(
        context: context,
        check: checkScreenConfiguration(
          duplicate: duplicateScreenMessage(error),
          unreadable: null,
        ),
        outputDirectory: outputDirectory,
        output: output,
      );
    }

    final Map<String, FigmaScreenSpec> specsOnDisk;
    try {
      specsOnDisk = await loadFigmaSpecs(
        projectDirectory,
        onProblem: output.line,
      );
    } on DuplicateScreenException catch (error) {
      output.line(output.red('$error'));
      return _blockedBeforePreflight(
        context: context,
        check: checkScreenConfiguration(
          duplicate: duplicateScreenMessage(error),
          unreadable: null,
        ),
        outputDirectory: outputDirectory,
        output: output,
      );
    }

    // Read and parsed here, bound further down. Everything from loading
    // the scenarios to binding the port stays inside a guard that
    // catches anything: before E-04 only ScenarioFormatException was
    // caught, so a malformed scenario file or an occupied port left the
    // process with an unhandled exception and exit 255 - a
    // configuration mistake reported as a crash.
    ScenarioLibrary? scenarios;
    ApiScenario? defaultScenario;
    final port = suite.mockApiPort;
    if (port != null) {
      try {
        scenarios = ScenarioLibrary.load(
          Directory('${projectDirectory.path}/mock_api/scenarios'),
        );
        defaultScenario = scenarios.resolve(ScenarioLibrary.defaultName);
      } on Object catch (error) {
        output
          ..line(output.red('The fixture server could not be started:'))
          ..line('  $error');
        return _blockedBeforePreflight(
          context: context,
          // `portFree: true` is not a claim that the port is free. It
          // has not been probed - that happens in preflight, which this
          // never reached - and reporting "port in use" over a scenario
          // that would not parse would be inventing a second finding
          // from no evidence. What was measured is what is reported.
          check: checkMockApi(
            port: port,
            portFree: true,
            scenarioProblem: error is ScenarioFormatException
                ? scenarioProblemMessage(error)
                : '$error',
            unresolvableFixtures: const [],
          ),
          outputDirectory: outputDirectory,
          output: output,
        );
      }
    }

    // 6. Arrange what the suite declares, then verify it - in that
    // order, so a fresh device is not refused over a state the very next
    // step was about to establish.
    await arrangeDeclaredPermissions(context, output);

    // 7. Preflight, before anything is started or launched. The mock
    // port has to be probed while it is still free, which is why this
    // runs before the fixture server rather than inside the runner.
    final preflight = await runPreflight(context);
    output.renderPreflight(preflight);

    if (preflight.isBlocked) {
      // Written even here, and especially here: CI wants a
      // machine-readable answer whether or not a test ran, and "we could
      // not test it" is an answer.
      final result = blockedSuiteResult(
        suite: suite,
        profile: profile,
        preflight: preflight,
        startedAt: DateTime.now().toUtc(),
      );
      final written = await _write(result, outputDirectory, output);
      _summarise(result, output, outputDirectory, written: written);
      return written ? result.exitCode : _error;
    }

    // A screen may declare its design on the test rather than having it
    // pulled to disk beforehand, and E-06 §4 says a declared
    // `figmaSource:` wins over an on-disk `figma/<screen>.json` - "a
    // stale on-disk spec silently shadowing a URL somebody declared is
    // exactly the quiet wrongness this platform exists to avoid".
    //
    // `testsmith run` has always done this. A suite did not: it passed only
    // the on-disk specs, so a suite validated a declared screen against
    // whatever happened to be on disk, and a declaration that could not
    // be resolved went unreported rather than becoming a Figma-source
    // error. The same three functions, in the same order, so there is
    // one resolution rule rather than two.
    //
    // The resolver is given its own secrets, as `testsmith run` gives it
    // one: the Figma token lives in the environment or a `.env` that is
    // not committed. It is deliberately *not* handed to `FlowRunner`
    // below - a suite has never resolved secrets for anything else, and
    // changing that is a separate question from this contract.
    final secrets = EnvSecretResolver(
      dotenv: DotEnv.load([projectDirectory.path, Directory.current.path]),
    );
    final (declaredSpecs, figmaFailures) = await resolveFigmaSources(
      project: projectDirectory,
      mappings: mappings,
      secrets: secrets,
    );
    for (final entry in figmaFailures.entries) {
      output.line(output.red('  figma: ${entry.key}: ${entry.value}'));
    }

    // 8. The fixture server, once for the whole suite.
    //
    // Only the binding is left here; the scenarios were read and
    // resolved above, where a malformed one is a configuration answer
    // rather than a server that would not start. The guard still
    // catches anything, for the occupied-port half of E-04.
    MockApiServer? mockApi;
    if (port != null) {
      try {
        mockApi = await MockApiServer.start(
          scenario: defaultScenario!,
          port: port,
        );
      } on Object catch (error) {
        output
          ..line(output.red('The fixture server could not be started:'))
          ..line('  $error');
        return _error;
      }
      output.line('  mock API        http://127.0.0.1:${mockApi.port}');
    }

    final server = mockApi;
    final result = await SuiteRunner(
      suite: suite,
      projectDirectory: projectDirectory,
      profile: profile,
      // Not null past the preflight verdict above: a suite with no
      // device chosen is blocked by the device check and returned there.
      device: AdbDeviceController(serial: serial!),
      execution: FlowRunner(
        projectDirectory: projectDirectory,
        deviceSerial: serial,
        mappings: mappings,
        // The same resolver the Figma sources above were resolved with,
        // and the same one `testsmith run` hands its own runner.
        //
        // Without it `FlowExecutor` falls back to `_DefaultSecrets`,
        // which reads the process environment and no `.env`. An
        // `apiSource:` whose `baseUrl` or `token` lived only in a `.env`
        // then resolved to nothing, the acquirer returned
        // `AcquisitionUnavailable`, and `api-to-ui` reported ERROR - so
        // the same flow measured under `testsmith run` and errored under a
        // suite, on a difference that had nothing to do with the
        // application.
        secrets: secrets,
        figmaFailures: figmaFailures,
        figmaSpecs: mergeFigmaSpecs(
          fromDisk: specsOnDisk,
          fromSource: declaredSpecs,
          onNote: output.line,
        ),
        mockApi: mockApi,
        target: suite.app.target,
        flavor: suite.app.flavor,
        dartDefines: suite.app.dartDefines,
        profile: profile,
        updateBaselines: args.flag('update-visual-baselines'),
        log: output.line,
      ),
      outputDirectory: outputDirectory,
      mockApi: mockApi,
      scenarios: scenarios,
      preflight: preflight,
      // Named, so the report says what was undone rather than leaving a
      // reader to assume it. The per-launch `adb reverse` is removed by
      // the session that created it, which is the only place that knows
      // it exists.
      teardown: {
        if (server != null) 'fixture server': server.close,
      },
      log: output.line,
    ).run();

    final written = await _write(result, outputDirectory, output);
    _summarise(result, output, outputDirectory, written: written);

    return written ? result.exitCode : _error;
  }

  /// The report CI reads, for a blocker found before preflight could run.
  ///
  /// Step 5 reads the project for itself and refuses there - before the
  /// device, before preflight, before the fixture server binds a port -
  /// so these never reached the line at step 7 that writes the result. A
  /// gate therefore saw the same empty directory for "nothing ran
  /// because the suite is fine" as for "a mapping has a typo in it".
  ///
  /// The refusal stays exactly where 5e9c169 put it, and the lifecycle
  /// does not move to earn a report. Only the report is added, through
  /// the same [blockedSuiteResult] the preflight path already uses: one
  /// result format, and an exit code that still comes from
  /// [SuiteResult.exitCode] rather than from a constant written here.
  Future<int> _blockedBeforePreflight({
    required SuiteContext context,
    required PreflightCheck check,
    required Directory outputDirectory,
    required Output output,
  }) async {
    final result = blockedSuiteResult(
      suite: context.suite,
      profile: context.profile,
      preflight: PreflightReport([check]),
      startedAt: DateTime.now().toUtc(),
    );
    final written = await _write(result, outputDirectory, output);
    _summarise(result, output, outputDirectory, written: written);
    return written ? result.exitCode : _error;
  }

  /// Whether suite.json and suite.html were written. A failure is said,
  /// not thrown: it is 2 whatever the suite concluded, because the answer
  /// CI asked for is not there to read.
  Future<bool> _write(
    SuiteResult result,
    Directory directory,
    Output output,
  ) async {
    try {
      await directory.create(recursive: true);
      await File('${directory.path}/suite.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n',
      );
      await File('${directory.path}/suite.html')
          .writeAsString(renderSuiteReport(result));
    } on FileSystemException catch (error) {
      output
        ..line()
        ..line(output.red('The suite report could not be written to '
            '${directory.path}:'))
        ..line(output.dim('  ${describeWriteFailure(error)}'));
      return false;
    }
    return true;
  }

  void _summarise(
    SuiteResult result,
    Output output,
    Directory directory, {
    required bool written,
  }) {
    output
      ..line()
      ..line('SUITE: ${result.suiteName}')
      ..line('─' * 48);

    for (final test in result.tests) {
      final label = switch (test.verdict) {
        TestVerdict.pass => output.green('PASS '),
        TestVerdict.fail => output.red('FAIL '),
        // Not red. Red is this tool saying the application is wrong,
        // and an environment error says the opposite: nothing about the
        // application was established. Same rule the run report uses.
        TestVerdict.error => output.yellow('ERROR'),
        TestVerdict.skip => output.dim('SKIP '),
      };
      final seconds = (test.duration.inMilliseconds / 1000).toStringAsFixed(1);
      output.line('$label ${test.id.padRight(18)} ${seconds}s'
          '${test.required ? '' : output.dim('  (optional)')}');
      if (test.reason != null) {
        output.line(output.dim('       ${test.reason}'));
      }
    }

    final verdict = switch (result.verdict) {
      SuiteVerdict.pass => output.green('PASS'),
      SuiteVerdict.fail => output.red('FAIL'),
      SuiteVerdict.error => output.red('ERROR'),
      SuiteVerdict.skip => output.dim('SKIP'),
    };

    // The exit this command returns, and the paths only of files that are
    // there: a report path to nothing reads like evidence.
    output
      ..line()
      ..line('RESULT: $verdict  (exit ${written ? result.exitCode : _error})');
    if (written) {
      output
        ..line()
        ..line('  ${directory.path}/suite.json')
        ..line('  ${directory.path}/suite.html');
    }
  }
}
