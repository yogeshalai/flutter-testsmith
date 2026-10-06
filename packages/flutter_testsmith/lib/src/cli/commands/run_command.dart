import 'dart:io';

import 'package:ai_client/ai_client.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:flutter_testsmith/engine.dart';

import '../device_selection.dart';
import '../dotenv.dart';
import '../figma_source_resolver.dart';
import '../flow_executor.dart';
import '../flow_runner.dart';
import '../mock_api_server.dart';
import '../project_config.dart';
import '../secrets/env_secret_resolver.dart';
import '../output.dart';
import '../output_path.dart';
import '../project_root.dart';
import 'preflight_command.dart';

/// Runs a flow file end to end and writes the reports.
class RunCommand extends Command<int> {
  RunCommand() {
    argParser
      ..addOption(
        'app',
        help: 'Directory of the Flutter application under test. Defaults to '
            'the nearest directory at or above this one with a pubspec.yaml.',
      )
      ..addOption('device', abbr: 'd', help: 'Device serial.')
      ..addOption(
        'out',
        help: 'Where to write result.json, report.html and screenshots. '
            'Relative to the application under test; an absolute path is '
            'taken as written.',
        defaultsTo: 'out',
      )
      ..addOption(
        'mock-api',
        help: 'Serve the fixture API on this host port, mapped into the '
            'device with adb reverse.',
      )
      ..addOption(
        'fixture',
        help: 'Which scenario in <app>/mock_api/scenarios the mock API '
            'serves. Overrides the `fixture:` named by the flow. '
            'Defaults to "default".',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Passed through to the app build. Repeatable.',
      )
      ..addOption(
        'target',
        abbr: 't',
        help: 'Entry point to launch, when the app is not lib/main.dart. '
            'Passed straight to `flutter run -t`.',
      )
      ..addOption(
        'flavor',
        help: 'Build flavor, for an app that has them. Passed straight to '
            '`flutter run --flavor`.',
      )
      ..addFlag(
        'allow-proposed',
        negatable: false,
        help: 'Run a flow still marked `status: proposed`. For reviewing a '
            'generated scenario before accepting it - it is not approval. '
            'Approving means editing the file.',
      )
      ..addFlag(
        'ai',
        negatable: false,
        help: 'Ask a language model to explain any failures. Advisory '
            'only: it cannot change a verdict, and an outage cannot fail '
            'the run.',
      )
      ..addOption(
        'ai-provider',
        help: 'Overrides ai.yaml. One of: '
            'groq, openai, openrouter, together, ollama, custom.',
      )
      ..addOption('ai-model', help: 'Overrides the model in ai.yaml.')
      ..addFlag(
        'update-visual-baselines',
        negatable: false,
        help: 'Replace each compared screenshot baseline with this run. '
            'Review the diff before committing: this accepts whatever is '
            'on screen, including a regression.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a test flow and write a report.';

  @override
  String get invocation => 'testsmith run <flow.yaml>';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    if (args.rest.length != 1) {
      output.line(output.red('Expected exactly one flow file.'));
      output.line(output.dim('Usage: $invocation'));
      return 64;
    }

    // Read with the invocation, because it is part of it: a port that is
    // not a port is a mistake in how `run` was called, found without
    // opening a file, and it used to be dropped silently - no fixture
    // server, and the flow run against the real API.
    final int? port;
    try {
      port = parseMockApiPort(args.option('mock-api'));
    } on FormatException catch (error) {
      output
        ..line(output.red(error.message))
        ..line(output.dim('Usage: $invocation'));
      return 64;
    }

    // Every refusal from here to the launch is the run being wrong, not
    // the application: a flow, mapping, scenario or .env that cannot be
    // used, or a device that cannot be reached. So each is 2, as E-03
    // files "missing flow" and "invalid syntax" for a suite, and as the
    // same mistake is once the app is running - a mapping bound to a
    // node the design lacks is an ERROR, which `exitCodeForRun` makes 2.
    // 1 is left to `exitCodeForRun`, for an application that was
    // measured and was wrong; these returned 1 from when `run` had one
    // code for every failure.
    final flowFile = File(args.rest.single);
    if (!flowFile.existsSync()) {
      output.line(output.red('No such flow file: ${flowFile.path}'));
      return environmentExitCode;
    }

    final root = resolveProjectRoot(args.option('app'));
    if (!root.isFound) {
      output
        ..line(output.red(root.problem!))
        ..line(output.dim('  ${root.hint}'));
      return environmentExitCode;
    }
    final projectDirectory = root.directory!;
    final outputDirectory =
        resolveOutputDirectory(projectDirectory, args.option('out')!);
    // Before anything is built: the reports are written after the run,
    // and a run whose result has nowhere to go measured nothing anybody
    // can read.
    final outputProblem = outputDirectoryProblem(outputDirectory);
    if (outputProblem != null) {
      output
        ..line(output.red('--out cannot be used: $outputProblem'))
        ..line(output.dim(
          '  Name a directory, or remove what is in the way.',
        ));
      return environmentExitCode;
    }

    final TestFlow flow;
    try {
      flow = TestFlow.parse(
        await flowFile.readAsString(),
        source: flowFile.path,
      );
    } on FlowFormatException catch (error) {
      // A malformed flow fails before anything is launched: there is no
      // point building an APK to discover a typo.
      output.line(output.red(error.toString()));
      return environmentExitCode;
    } on FileSystemException catch (error) {
      // The other way the line above fails. `readAsString` decodes as
      // well as reads, and reports a failure to decode as a
      // `FileSystemException` - not a `FormatException`, so not the
      // clause above, and not caught anywhere over this one either. A
      // flow saved as UTF-16 with a byte-order mark, which is what
      // Notepad writes as "Unicode" and what PowerShell redirection
      // writes by default, ended the process at 255 with a stack trace
      // naming this tool's install path and not the file.
      //
      // Both of the other readers of a flow already answered this.
      // `preflight` reports it - "a permission, an encoding", says the
      // comment on its guard - and its remedy line says to run the flow
      // on its own to see the error in full, which was the one command
      // that could not. Same exit code as a typo: either way it is a
      // file to go and correct.
      output
        ..line(output.red('${flowFile.path} could not be read.'))
        ..line(output.dim('  ${error.message}'));
      return environmentExitCode;
    }

    if (flow.isProposed && !args.flag('allow-proposed')) {
      // A generated scenario nobody has read yet. Refused here rather
      // than by keeping it in a particular folder, so pointing the
      // runner straight at the file does not sidestep the review.
      output
        ..line(output.red('"${flow.name}" is marked `status: proposed`.'))
        ..line()
        ..line('It was generated, and nobody has reviewed it. Read it, '
            'arrange whatever state it needs, then delete the '
            '`status: proposed` line to accept it as a test.')
        ..line()
        ..line(output.dim('To try it without accepting it: '
            '--allow-proposed'));
      return environmentExitCode;
    }

    final Map<String, MappingsFile> mappings;
    try {
      mappings = await loadMappings(projectDirectory);
    } on MappingsFormatException catch (error) {
      output.line(output.red(error.toString()));
      return environmentExitCode;
    } on DuplicateScreenException catch (error) {
      // Refused rather than resolved: picking one of the two would make
      // this run's verdict depend on the order the filesystem happened
      // to list them in.
      output.line(output.red('$error'));
      return environmentExitCode;
    }

    // Everything the project can be judged on by itself, finished
    // before a device is looked for and before the fixture server binds
    // a port. It is the rule this file already states about a malformed
    // flow - "fails before anything is launched" - applied to the rest
    // of the configuration, and it is what stops a laptop with nothing
    // plugged in being told about the device when the real answer is
    // two files describing one screen.
    final Map<String, FigmaScreenSpec> specsOnDisk;
    try {
      specsOnDisk = await loadFigmaSpecs(
        projectDirectory,
        onProblem: output.line,
      );
    } on DuplicateScreenException catch (error) {
      output.line(output.red('$error'));
      return environmentExitCode;
    }

    // Read with the rest of the configuration, not after the run. It is
    // advisory, so a configuration that cannot be used is said and the
    // run goes on without an analysis - never refused, and never, as it
    // was when this was read at the end, a crash after everything was
    // measured. The headline names no file: the mistake may be in
    // `--ai-provider` rather than ai.yaml, and the detail says which -
    // a problem with the file names its path.
    LlmConfig? aiConfig;
    String? aiProblem;
    if (args.flag('ai')) {
      try {
        aiConfig = loadAiConfig(
          projectDirectory,
          provider: args.option('ai-provider'),
          model: args.option('ai-model'),
        );
      } on FormatException catch (error) {
        aiProblem = '$error';
        output
          ..line(output.yellow(
            'The AI configuration cannot be used, so there will be no AI '
            'analysis:',
          ))
          ..line(output.dim('  ${error.message}'));
      }
    }

    final wanted = args.option('fixture') ?? flow.fixture;

    // A flow that names an API state is only a test when that state is
    // actually arranged. Running it against whatever happened to be
    // loaded would report coverage that does not exist - the same
    // reasoning as refusing a `status: proposed` flow.
    if (wanted != null && port == null) {
      output
        ..line(output.red('"${flow.name}" needs the "$wanted" API state.'))
        ..line()
        ..line('Start the fixture server so it can be arranged:')
        ..line(output.dim('  --mock-api 8080'));
      return environmentExitCode;
    }

    // Read and parsed here; bound further down, once there is a device
    // for it to serve. A scenario file that will not parse is a fact
    // about the project, and nothing needs to be open to discover it.
    final ApiScenario? scenario;
    if (port != null) {
      // Guarded as `resolve` is below. The load is where each file is
      // read and parsed, so a scenario that is not JSON, or is in an
      // encoding that cannot be read, raises here - and it used to reach
      // `bin/testsmith.dart` unhandled, at exit 255.
      final ScenarioLibrary library;
      try {
        library = ScenarioLibrary.load(
          Directory('${projectDirectory.path}/mock_api/scenarios'),
        );
      } on ScenarioFormatException catch (error) {
        output.line(output.red('$error'));
        return environmentExitCode;
      }
      final name = wanted ?? ScenarioLibrary.defaultName;

      if (!library.contains(name)) {
        output
          ..line(output.red('No API scenario named "$name".'))
          ..line()
          ..line('Looked in ${library.directory.path}.')
          ..line('Available: '
              '${library.names.isEmpty ? '(none)' : library.names.join(', ')}');
        return environmentExitCode;
      }

      try {
        scenario = library.resolve(name);
      } on ScenarioFormatException catch (error) {
        output.line(output.red('$error'));
        return environmentExitCode;
      }
    } else {
      scenario = null;
    }

    // No adb, no device, several with none chosen, or a named one that is
    // not attached: the run cannot reach anything to measure, which is
    // the run being wrong rather than the application - 2, as a launch
    // that fails below is, and as `suite run` answers the same machine.
    final serial = args.option('device') ?? await selectSoleDevice(output);
    if (serial == null) return environmentExitCode;
    if (!await verifyDevice(serial, output)) return environmentExitCode;

    output
      ..line(output.bold('${flow.name}  ${output.dim(flowFile.path)}'))
      ..line();

    MockApiServer? mockApi;
    if (port != null) {
      final ready = scenario!;
      try {
        mockApi = await MockApiServer.start(scenario: ready, port: port);
      } on Object catch (error) {
        // The sentence `suite run` has always used for this, because it
        // is the same failure: the port is taken, or the host refused
        // it. Unguarded, the SocketException reached
        // `bin/testsmith.dart`, which catches UsageException and
        // nothing else - exit 255 and a stack trace for a port somebody
        // else is using. E-04 names that outcome as the one it removed,
        // and removed it only for a suite.
        //
        // Nothing to close: the server never started. Exit 2 for the
        // reason above, and the code `suite run` gives this failure.
        output
          ..line(output.red('The fixture server could not be started:'))
          ..line('  $error');
        return environmentExitCode;
      }
      output.line('› mock API on http://127.0.0.1:${mockApi.port} '
          'serving "${ready.name}"'
          '${ready.description.isEmpty ? '' : ' - ${ready.description}'}');
    }

    // Credentials come from the process environment first, then a .env
    // file that is not committed. Never from a flag, which would put
    // them in shell history and the process list.
    //
    // A `.env` that is there and cannot be decoded is a file to correct,
    // at the code every other pre-launch configuration error here uses.
    // The fixture server may already be up; the `finally` below is not
    // entered yet, so it is closed here.
    final DotEnv dotenv;
    try {
      dotenv = DotEnv.load([projectDirectory.path, Directory.current.path]);
    } on FormatException catch (error) {
      output.line(output.red('$error'));
      await mockApi?.close();
      return environmentExitCode;
    }
    final secrets = EnvSecretResolver(dotenv: dotenv);

    // Asked before the launch, as `inspect` and `smoke` ask it: without
    // this, a machine with no Flutter had its handset woken and then
    // heard "Could not start the app: ProcessException" quoting the Dart
    // runtime's own source file. After the device and every
    // configuration check, because a mistyped serial or a broken file is
    // a statement about the invocation, and answering it with "install
    // Flutter" would name the wrong problem. Before the Figma sources,
    // which may go to the network for a run that cannot start. Exit 2,
    // as every refusal before launch here is. No working machine is
    // refused: the resolver accepts the same `.bat`/`.cmd`/`.exe` a bare
    // launch would run.
    final flutter = resolveFlutter();
    if (!flutter.isFound) {
      output
        ..line(output.red(flutter.problem!))
        ..line(output.dim('  ${flutter.hint}'));
      await mockApi?.close();
      return environmentExitCode;
    }

    // A screen may declare its design on the test rather than having it
    // pulled to disk beforehand. Resolved once, through the same client
    // and the same cache `testsmith figma pull` uses.
    final (declaredSpecs, figmaFailures) = await resolveFigmaSources(
      project: projectDirectory,
      mappings: mappings,
      secrets: secrets,
    );
    for (final entry in figmaFailures.entries) {
      output.line(output.red('  figma: ${entry.key}: ${entry.value}'));
    }

    final RunResult result0;
    try {
      result0 = await FlowRunner(
        projectDirectory: projectDirectory,
        deviceSerial: serial,
        mappings: mappings,
        secrets: secrets,
        figmaFailures: figmaFailures,
        figmaSpecs: mergeFigmaSpecs(
          fromDisk: specsOnDisk,
          fromSource: declaredSpecs,
          onNote: output.line,
        ),
        mockApi: mockApi,
        target: args.option('target'),
        flavor: args.option('flavor'),
        dartDefines: args.multiOption('dart-define'),
        updateBaselines: args.flag('update-visual-baselines'),
        log: output.line,
      ).execute(
        flow: flow,
        outputDirectory: outputDirectory,
        fixture: wanted,
      );
    } catch (error) {
      // The app never started, or the run could not be completed.
      // Report it plainly: a stack trace here says nothing the message
      // does not.
      //
      // Exit 2, the same code a suite returns for a test it could not
      // set up and the same code `exitCodeForRun` gives a run whose
      // verdict is ERROR. The CI contract this repository already states
      // is 0 passed, 1 something is wrong with the application, 2
      // something is wrong with the run - and a launch that never
      // happened is the second kind of news. `exitCodeForRun` was fixed
      // for finished runs and this path, which never produces a result
      // to hand it, kept returning 1: an application that would not
      // start sent someone to read a screen nobody had measured.
      output
        ..line()
        ..line(output.red('Could not start the app: $error'))
        ..line(output.dim(
          '  Nothing was measured, so there is no verdict and no report.',
        ));
      await mockApi?.close();
      return environmentExitCode;
    } finally {
      if (mockApi != null) {
        _reportServed(mockApi, output);
      }
    }
    await mockApi?.close();

    var result = result0;

    // After the run is complete and its verdict fixed. The analyst is
    // handed a finished result and returns a copy with an explanation
    // attached; it has nothing left to change.
    if (args.flag('ai')) {
      result = result.withAnalysis(
        await _analyse(result, aiConfig, aiProblem, dotenv, output),
      );
    }

    // The verdict is still printed when the reports could not be written,
    // because it was measured. The exit is 2: whatever reads result.json
    // has no result to read, and that is the run being wrong.
    final written = await _writeReports(result, outputDirectory, output);
    _summarise(result, output);

    return written ? exitCodeForRun(result) : environmentExitCode;
  }

  /// Prints what the fixture server actually answered.
  ///
  /// Worth showing: "the screen is empty" and "the app never called the
  /// endpoint" look identical on a device, and this is what separates
  /// them. An unmatched route is called out, because a scenario missing
  /// a route the app really uses is a fixture bug wearing a 404.
  void _reportServed(MockApiServer mock, Output output) {
    if (mock.exchanges.isEmpty) {
      output..line()..line(output.dim('mock API: no requests were made'));
      return;
    }
    output..line()..line(output.dim('mock API served'));
    for (final exchange in mock.exchanges) {
      final note = exchange.matched
          ? (exchange.delayMs > 0 ? ' after ${exchange.delayMs}ms' : '')
          : '  ! no route in "${mock.scenario.name}"';
      output.line(output.dim('  ${exchange.status}  ${exchange.method} '
          '${exchange.path}$note'));
    }
  }

  /// Explains the failures, if a model can be reached.
  ///
  /// Every path returns an outcome rather than throwing. The verdicts
  /// were decided before this ran, and a missing key or an unreachable
  /// provider is not evidence about the application under test.
  ///
  /// [config] was read before the run; [problem] is why it could not be,
  /// already said to the reader then. The key comes from the `.env` the
  /// run already loaded.
  Future<AnalysisOutcome> _analyse(
    RunResult result,
    LlmConfig? config,
    String? problem,
    DotEnv dotenv,
    Output output,
  ) async {
    if (config == null) {
      return AnalysisUnavailable(problem ?? 'ai.yaml could not be read');
    }

    final key = dotenv[config.apiKeyEnv];

    final LlmClient client;
    try {
      client = OpenAiCompatibleClient(config: config, apiKey: key);
    } on LlmException catch (error) {
      return AnalysisUnavailable(error.message);
    }

    output.line('› asking ${client.describe} to explain the failures');
    try {
      return await FailureAnalyst(client).analyse(result);
    } finally {
      client.close();
    }
  }

  /// Whether both reports were written. A failure is said, not thrown:
  /// unguarded, it reached `bin/testsmith.dart` at exit 255 with a stack
  /// trace, after a run that had finished.
  Future<bool> _writeReports(
    RunResult result,
    Directory directory,
    Output output,
  ) async {
    final ({File json, File html}) written;
    try {
      written = await writeRunReports(result, directory);
    } on FileSystemException catch (error) {
      output
        ..line()
        ..line(output.red('The report could not be written to '
            '${directory.path}:'))
        ..line(output.dim('  ${describeWriteFailure(error)}'));
      return false;
    }
    output
      ..line()
      ..line('  ${written.json.path}')
      ..line('  ${written.html.path}');
    return true;
  }

  void _summarise(RunResult result, Output output) {
    // The sectioned report first: a reader wants to know which layer
    // gave way before they want the per-screen detail. See Phase 12.
    output.line();
    for (final line in const E2eSummary().renderLines(result)) {
      output.line(_colourise(line, output));
    }

    output..line()..line(output.bold('Result'));

    for (final screen in result.screens) {
      final report = screen.report;
      // The screen's own verdict, read rather than recomputed. It is the
      // same value `result.json` now carries, so the terminal and the
      // file cannot disagree about a screen.
      output.line('  ${screen.screenId}  '
          '${_badge(screen.status, output)}'
          '  ${output.dim('${report.passCount} ok, ${report.failCount} '
              'failed, ${report.skipCount} skipped, '
              '${report.errorCount} errored')}');

      for (final failure in report.failures) {
        output.line('    ${output.red('✗')} ${failure.message}');
        if (failure.expected != null || failure.actual != null) {
          output
            ..line('        expected  ${output.green('${failure.expected}')}')
            ..line('        actual    ${output.red('${failure.actual}')}');
        }
      }

      // Said out loud, and apart from the failures. `report.failures` is
      // FAIL only, so a screen that errored printed a red headline and
      // no reason whatever - the reader could see a count of 1 errored
      // and nothing about what could not be done.
      for (final blocked in report.results) {
        if (blocked.status != ValidationStatus.error) continue;
        output.line('    ${output.yellow('!')} ${blocked.message}');
      }
    }

    _summariseAnalysis(result.analysis, output);

    output
      ..line()
      ..line(
        switch (result) {
          // Yellow rather than red, and worded rather than abbreviated.
          // Red FAIL is this tool saying the application is wrong, and
          // it had no business saying that about a screen it had lost
          // the ability to look at.
          _ when result.observationFailed =>
            output.yellow('OBSERVATION FAILED  (the run, not the app)'),
          // Otherwise the run's own verdict, so this banner and the
          // dimension block printed above it cannot disagree.
          _ => _badge(result.overall, output),
        },
      );
  }

  /// One status, rendered as the word it is.
  ///
  /// The distinction this milestone exists for: PASS and FAIL are claims
  /// about the application, ERROR says a check could not be run, and
  /// SKIP says none was. Only one of the four is red.
  String _badge(ValidationStatus status, Output output) => switch (status) {
        ValidationStatus.pass => output.green('PASS'),
        ValidationStatus.fail => output.red('FAIL'),
        ValidationStatus.error => output.yellow('ERROR'),
        ValidationStatus.skip => output.dim('SKIP'),
      };

  /// Prints the analysis after the verdict lines, never among them.
  ///
  /// Each claim is labelled with how well the evidence supports it, and
  /// the heading says whose opinion this is. Someone scanning a
  /// terminal must not come away thinking a model decided anything.
  void _summariseAnalysis(AnalysisOutcome? outcome, Output output) {
    switch (outcome) {
      case null:
        return;

      case AnalysisSkipped(:final reason) ||
            AnalysisUnavailable(:final reason):
        output..line()..line(output.dim('AI analysis: $reason'));

      case AnalysisReady(:final analysis):
        // Said once, plainly, above everything the model wrote.
        final provenance = output.dim(
          '(${analysis.provider}/${analysis.model} - explanation, '
          'not a verdict)',
        );
        output
          ..line()
          ..line('${output.bold('AI analysis')} $provenance')
          ..line('  ${analysis.summary}');

        for (final finding in analysis.findings) {
          final where = finding.elementId == null
              ? finding.validatorId
              : '${finding.validatorId} ${finding.elementId}';
          final confidence = finding.confidence == null
              ? ''
              : ' ${output.dim('(model confidence '
                  '${(finding.confidence! * 100).round()}%)')}';

          output.line('    ${_claimLabel(finding.classification, output)} '
              '${output.dim(where)}');
          output.line('      ${finding.explanation}$confidence');

          for (final check in finding.suggestedChecks) {
            output.line('      ${output.dim('next: $check')}');
          }
        }
    }
  }

  /// Colours a summary line by the mark it starts with.
  ///
  /// The renderer stays plain text on purpose - it is unit-tested, and
  /// the same lines go into a file where escape codes are noise. Colour
  /// is added here, where a terminal is known to be on the other end.
  String _colourise(String line, Output output) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('✓')) return output.green(line);
    if (trimmed.startsWith('✗')) return output.red(line);
    if (trimmed.startsWith('BLOCKED')) return output.red(line);
    if (trimmed.startsWith('RESULT: PASS')) return output.green(line);
    if (trimmed.startsWith('RESULT: FAIL')) return output.red(line);
    if (trimmed.startsWith('-')) return output.dim(line);
    if (line == line.toUpperCase() && trimmed.isNotEmpty) {
      return output.bold(line);
    }
    return line;
  }

  String _claimLabel(FindingClass level, Output output) => switch (level) {
        FindingClass.confirmedFailure => output.red('[confirmed]'),
        FindingClass.probableCause => output.bold('[probable cause]'),
        FindingClass.hypothesis => output.dim('[hypothesis]'),
      };
}
