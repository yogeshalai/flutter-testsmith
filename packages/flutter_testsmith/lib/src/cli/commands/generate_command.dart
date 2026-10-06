import 'dart:io';

import 'package:ai_client/ai_client.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_testsmith/engine.dart';

import '../dotenv.dart';
import '../output.dart';
import '../output_path.dart';
import '../mock_api_server.dart';
import '../project_config.dart';
import '../project_indexer.dart';
import '../project_root.dart';

/// Proposes edge-case scenarios for a screen.
///
/// Everything it writes is inert: each flow is stamped
/// `status: proposed`, and `testsmith run` refuses those. Accepting one
/// means reading it and deleting that line.
class GenerateCommand extends Command<int> {
  GenerateCommand() {
    argParser
      ..addOption(
        'app',
        help: 'Directory of the Flutter application under test. Defaults to '
            'the nearest directory at or above this one with a pubspec.yaml.',
      )
      ..addOption(
        'screen',
        help: 'Screen to propose scenarios for. Defaults to the one with '
            'mappings configured.',
      )
      ..addOption(
        'out',
        help: 'Where to write proposals. Relative to the application; '
            'an absolute path is taken as written.',
        defaultsTo: 'tests/proposed',
      )
      ..addOption('ai-provider', help: 'Overrides ai.yaml.')
      ..addOption('ai-model', help: 'Overrides the model in ai.yaml.')
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the proposals without writing any files.',
      );
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Propose edge-case test scenarios. Proposals never run until a '
      'person accepts them.';

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    final root = resolveProjectRoot(args.option('app'));
    if (!root.isFound) {
      output
        ..line(output.red(root.problem!))
        ..line(output.dim('  ${root.hint}'));
      return 1;
    }
    final project = root.directory!;

    final index = ProjectIndexer(project).build(
      onProblem: (problem) => output.line('  ! $problem'),
    );

    final GenerationEvidence evidence;
    try {
      evidence = await _gather(project, index, args.option('screen'));
    } on StateError catch (error) {
      output.line(output.red(error.message));
      return 1;
    } on DuplicateScreenException catch (error) {
      // Introduced by reading through `loadMappings`, and refused here
      // for the reason it is refused everywhere else: neither file is
      // the winner, because there is no winner.
      output.line(output.red('$error'));
      return 1;
    } on MappingsFormatException catch (error) {
      // A file the operator wrote, and a line of it to correct. The
      // indexer already skipped it with a warning; reaching the parser a
      // second time from here is what used to end the command as a stack
      // trace, which says nothing about which key was wrong.
      output.line(output.red('$error'));
      return 1;
    } on ScenarioFormatException catch (error) {
      // The same, for a fixture. `_apiSample` tolerates one because a
      // sample is a convenience; the fixture *list* is evidence the
      // proposal is built from, so a scenario nobody can read stops the
      // command rather than quietly shortening that list.
      output.line(output.red('$error'));
      return 1;
    }

    final LlmClient client;
    try {
      client = _client(project, args);
    } on FormatException catch (error) {
      output.line(output.red('$error'));
      return 1;
    } on LlmException catch (error) {
      output.line(output.red(error.message));
      return 1;
    }

    output
      ..line(output.bold('Proposing scenarios for ${evidence.screen}'))
      ..line(output.dim('  ${client.describe} · '
          '${evidence.elements.length} element(s) · '
          '${evidence.existingFlows.length} existing flow(s)'))
      ..line();

    final GenerationOutcome outcome;
    try {
      outcome = await TestGenerator(client).propose(evidence: evidence);
    } finally {
      client.close();
    }

    switch (outcome) {
      case GenerationUnavailable(:final reason):
        output.line(output.red('No proposals: $reason'));
        return 1;

      case GenerationReady(:final scenarios, :final rejected):
        for (final rejection in rejected) {
          // Shown rather than swallowed: a model that keeps inventing a
          // step is a prompt problem worth seeing.
          output.line('  ${output.dim('rejected')} ${rejection.name}  '
              '${output.dim(rejection.reason)}');
        }
        if (rejected.isNotEmpty) output.line();

        if (scenarios.isEmpty) {
          output.line('Nothing proposed.');
          return 0;
        }

        return _write(scenarios, project, args, output);
    }
  }

  int _write(
    List<ProposedScenario> scenarios,
    Directory project,
    ArgResults args,
    Output output,
  ) {
    final directory = resolveOutputDirectory(project, args.option('out')!);
    final dryRun = args.flag('dry-run');
    if (!dryRun) directory.createSync(recursive: true);

    for (final scenario in scenarios) {
      final file = File('${directory.path}/${scenario.name}.yaml');

      output
        ..line('  ${output.green('proposed')} ${scenario.name}  '
            '${output.dim(scenario.category)}')
        ..line('      ${scenario.rationale}');
      if (scenario.precondition != null) {
        output.line('      ${output.dim('needs: ${scenario.precondition}')}');
      }

      if (dryRun) {
        output.line(output.dim('      (not written: --dry-run)'));
        continue;
      }

      if (file.existsSync()) {
        // Never overwrite. A proposal may already have been edited.
        output.line(output.dim('      already at ${file.path}, left alone'));
        continue;
      }

      file.writeAsStringSync(_withHeader(scenario));
      output.line(output.dim('      ${file.path}'));
    }

    output
      ..line()
      ..line('${scenarios.length} proposal(s). None of them will run: each '
          'is marked `status: proposed`.')
      ..line(output.dim('Read one, arrange the state it needs, then delete '
          'that line to accept it.'));

    return 0;
  }

  /// Puts the reasoning in the file, where whoever reviews it is.
  String _withHeader(ProposedScenario scenario) {
    final buffer = StringBuffer()
      ..writeln('# PROPOSED - generated, and not yet reviewed by anyone.')
      ..writeln('#')
      ..writeln('# Why: ${scenario.rationale}');
    if (scenario.precondition != null) {
      buffer.writeln('# Needs: ${scenario.precondition}');
    }
    if (scenario.confidence != null) {
      buffer.writeln(
        '# Model confidence: ${(scenario.confidence! * 100).round()}%',
      );
    }
    buffer
      ..writeln('#')
      ..writeln('# `testsmith run` refuses this while the status line below is')
      ..writeln('# present. Delete it to accept this as a test.')
      ..writeln();

    return '$buffer${scenario.flowYaml.trim()}\n';
  }

  Future<GenerationEvidence> _gather(
    Directory project,
    ImpactIndex index,
    String? wantedScreen,
  ) async {
    // Through the loader every other command uses, rather than reading
    // the directory here. Listed and parsed in place, this answered two
    // questions by whichever file `listSync` handed back first: which
    // screen to propose for when none was named, and which of two files
    // claiming one screen won. `Directory.listSync()` order is
    // unspecified by dart:io, so the same project proposed scenarios for
    // a different screen on a different filesystem - and the duplicate
    // `run` and `suite run` refuse outright went unnoticed here.
    final mappings = await loadMappings(project);

    if (mappings.isEmpty) {
      throw StateError(
        'No mappings found in ${project.path}/mappings. A scenario needs '
        'to know what the screen shows and where it comes from.',
      );
    }

    // Sorted, so the list a reader is given is the same on every machine.
    final known = mappings.keys.toList()..sort();

    final MappingsFile chosen;
    if (wantedScreen != null) {
      final named = mappings[wantedScreen];
      if (named == null) {
        throw StateError(
          'No mappings for "$wantedScreen". Known: ${known.join(', ')}.',
        );
      }
      chosen = named;
    } else if (mappings.length == 1) {
      chosen = mappings.values.single;
    } else {
      // The rule `selectSoleDevice` holds to for handsets: refusing to
      // pick one of several is the whole point, because a proposal built
      // for a screen nobody asked about reads exactly like one they did.
      throw StateError(
        'Several screens are configured; name the one to propose for with '
        '--screen. Known: ${known.join(', ')}.',
      );
    }

    final entry = index.flows.firstWhere(
      (flow) => flow.touchesScreen(chosen.screen),
      orElse: () => throw StateError(
        'No existing flow reaches "${chosen.screen}", so a proposal would '
        'have to invent the navigation. Write one flow that gets there '
        'first.',
      ),
    );

    // Every semantic id the sources declare for this screen, plus the
    // ones the mappings already name.
    final elements = <String>{
      for (final mapping in chosen.mappings) mapping.target,
      for (final file in index.files.values)
        if (file.screens.contains(chosen.screen)) ...file.elements,
    };

    return GenerationEvidence(
      appId: _appIdFrom(project),
      screen: chosen.screen,
      // The navigation itself, so a proposal copies what is known to
      // work instead of being handed a path it might use as a name.
      entryFlow: _stepsOf(File(entry.path)),
      knownScreens: {
        for (final flow in index.flows) ...flow.screens,
        for (final file in index.files.values) ...file.screens,
      }.toList()
        ..sort(),
      // Every id in the app, so navigating through another screen is
      // not mistaken for inventing one.
      knownElements: {
        for (final file in index.files.values) ...file.elements,
        for (final flow in index.flows) ...flow.elements,
      }.toList()
        ..sort(),
      apiSample: _apiSample(project),
      fixtures: ScenarioLibrary.load(
        Directory('${project.path}/mock_api/scenarios'),
      ).names,
      elements: elements.toList()..sort(),
      existingFlows: [for (final flow in index.flows) flow.name],
      coveredConditions: [for (final rule in chosen.rules) rule.condition],
    );
  }

  /// The `steps:` block of a flow, verbatim.
  String _stepsOf(File file) {
    if (!file.existsSync()) return '';

    final lines = file.readAsStringSync().split('\n');
    final at = lines.indexWhere((l) => RegExp(r'^\s*steps\s*:').hasMatch(l));
    return at == -1 ? '' : lines.skip(at).join('\n').trim();
  }

  /// A real response from the default scenario, which shows field
  /// names, types and plausible values all at once - more useful than a
  /// schema, and guaranteed to be what the app will actually receive.
  Map<String, Object?> _apiSample(Directory project) {
    try {
      final scenario = ScenarioLibrary.load(
        Directory('${project.path}/mock_api/scenarios'),
      ).resolve(ScenarioLibrary.defaultName);

      final route = scenario.match('GET', '/products/123');
      final body = route?.body;
      if (body is Map) return body.cast<String, Object?>();
    } on ScenarioFormatException {
      // Proposing tests is a convenience; a missing fixture directory
      // makes the sample empty rather than failing the command.
    }
    return const {};
  }

  String _appIdFrom(Directory project) {
    final tests = Directory('${project.path}/tests');
    if (!tests.existsSync()) return 'unknown';

    // Sorted, for the reason R9 sorted this command's mapping choice:
    // `Directory.listSync` order is unspecified by dart:io and is not
    // the same on every filesystem, so "the first flow that parses"
    // made the answer a property of the machine. With one flow, or
    // several naming one application - which is the ordinary case,
    // since `appId` is the application under test - nothing changes;
    // where they disagree, the same set of files now names the same
    // application everywhere.
    final candidates = tests
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.yaml'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in candidates) {
      try {
        return TestFlow.parse(file.readAsStringSync(), source: file.path)
            .appId;
      } on FlowFormatException {
        continue;
      } on FileSystemException {
        // `readAsStringSync` decodes as well as reads and reports a
        // failure to decode as a `FileSystemException`, which the
        // clause above does not catch. The same policy either way: a
        // flow this cannot use is not the one to take an appId from,
        // and the next one is tried. Skipped silently, as a malformed
        // flow already is - the indexer has already reported the file,
        // and saying it twice would read like two problems.
        continue;
      }
    }
    return 'unknown';
  }

  LlmClient _client(Directory project, ArgResults args) {
    // A file that cannot be decoded or parsed is a `FormatException`,
    // which the caller renders as a configuration error at exit 1.
    final config = loadAiConfig(
      project,
      provider: args.option('ai-provider'),
      model: args.option('ai-model'),
    );

    final env = DotEnv.load([project.path, Directory.current.path]);
    return OpenAiCompatibleClient(
      config: config,
      apiKey: env[config.apiKeyEnv],
    );
  }
}
