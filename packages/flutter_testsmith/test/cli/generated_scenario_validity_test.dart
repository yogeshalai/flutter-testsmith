import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith/src/cli/mock_api_server.dart';
import 'package:flutter_testsmith/src/cli/project_indexer.dart';
import 'package:flutter_testsmith/engine.dart';

/// Phase 12, brief item 9 - every committed proposal must be real.
///
/// This runs over the files that are actually in the repository, not
/// over a fixture of them. The Phase 12 baseline found seven committed
/// proposals, each declaring a precondition nothing could arrange and
/// one naming a field the API does not have. They parsed. They
/// referenced real ids. Approving any of them would have added a test
/// that runs against the default state under an edge-case name.

Directory get app {
  for (final candidate in [
    'examples/ecommerce_app',
    '../../examples/ecommerce_app',
  ]) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  fail('cannot find the example application from ${Directory.current.path}');
}

List<File> proposalFiles() {
  final directory = Directory('${app.path}/tests/proposed');
  if (!directory.existsSync()) return const [];
  return [
    for (final entry in directory.listSync().whereType<File>())
      if (entry.path.endsWith('.yaml')) entry,
  ];
}

void main() {
  late ImpactIndex index;
  late ScenarioLibrary fixtures;
  late Set<String> knownScreens;
  late Set<String> knownElements;

  setUpAll(() {
    index = ProjectIndexer(app).build();
    fixtures = ScenarioLibrary.load(Directory('${app.path}/mock_api/scenarios'));

    knownScreens = {
      for (final flow in index.flows) ...flow.screens,
      for (final file in index.files.values) ...file.screens,
    };
    knownElements = {
      for (final file in index.files.values) ...file.elements,
      for (final flow in index.flows) ...flow.elements,
    };
  });

  test('there are proposals to check', () {
    // A vacuously passing suite would be the worst outcome here.
    expect(proposalFiles(), isNotEmpty);
  });

  for (final file in proposalFiles()) {
    final name = file.uri.pathSegments.last;

    group(name, () {
      late TestFlow flow;

      setUp(() {
        flow = TestFlow.parse(file.readAsStringSync(), source: file.path);
      });

      test('parses', () {
        // Asserted by setUp reaching here. A generated file that breaks
        // the suite is worse than no file.
        expect(flow.name, isNotEmpty);
      });

      test('is marked proposed, so the runner refuses it', () {
        expect(flow.status, FlowStatus.proposed);
        expect(flow.isProposed, isTrue);
      });

      test('names a fixture that exists, or declares its state in prose',
          () {
        final fixture = flow.fixture;
        if (fixture != null) {
          expect(
            fixtures.contains(fixture),
            isTrue,
            reason: '"$fixture" is not in ${fixtures.directory.path}. '
                'Available: ${fixtures.names.join(', ')}',
          );
          // And it resolves, inheritance and all.
          expect(() => fixtures.resolve(fixture), returnsNormally);
        } else {
          expect(
            file.readAsStringSync(),
            contains('# Needs:'),
            reason: 'a scenario with no fixture must at least say what '
                'state it needs, or running it tests the default state '
                'under this name',
          );
        }
      });

      test('every screen it expects exists', () {
        for (final step in flow.steps) {
          if (step is ExpectScreenStep) {
            expect(
              knownScreens,
              contains(step.screenId),
              reason: 'the application has: '
                  '${(knownScreens.toList()..sort()).join(', ')}',
            );
          }
        }
      });

      test('every element it touches exists', () {
        for (final step in flow.steps) {
          final id = switch (step) {
            TapStep(:final elementId) => elementId,
            InputStep(:final elementId) => elementId,
            ExpectElementStep(:final elementId) => elementId,
            _ => null,
          };
          if (id == null) continue;
          expect(
            knownElements,
            contains(id),
            reason: '"$id" is not a semantic id this application declares',
          );
        }
      });

      test('it does not overwrite a reviewed flow', () {
        final approved = [
          for (final coverage in index.flows) coverage.name,
        ];
        expect(approved, isNot(contains(flow.name)));
      });
    });
  }

  group('the approval gate as a whole', () {
    test('no proposal is offered to test selection', () {
      // ProjectIndexer skips a proposed flow, so impact analysis can
      // never suggest running something nobody has reviewed.
      final names = index.flows.map((f) => f.name).toSet();
      for (final file in proposalFiles()) {
        final flow =
            TestFlow.parse(file.readAsStringSync(), source: file.path);
        expect(names, isNot(contains(flow.name)));
      }
    });

    test('every approved flow naming a fixture names one that exists', () {
      // The same rule, applied to the tests a person did write: a flow
      // whose fixture was renamed away is refused at run time, and this
      // catches it at commit time instead.
      for (final entry
          in Directory('${app.path}/tests').listSync().whereType<File>()) {
        if (!entry.path.endsWith('.yaml')) continue;
        final flow =
            TestFlow.parse(entry.readAsStringSync(), source: entry.path);
        final fixture = flow.fixture;
        if (fixture == null) continue;

        expect(
          fixtures.contains(fixture),
          isTrue,
          reason: '${entry.path} needs "$fixture"',
        );
      }
    });
  });
}
