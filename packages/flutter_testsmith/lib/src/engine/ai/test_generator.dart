import 'dart:convert';

import 'package:flutter_testsmith/ai.dart';
import 'package:meta/meta.dart';

import '../dsl/steps.dart';
import '../dsl/test_flow.dart';

/// What the generator knows about a screen worth proposing tests for.
@immutable
class GenerationEvidence {
  const GenerationEvidence({
    required this.appId,
    required this.screen,
    required this.entryFlow,
    this.apiSample = const {},
    this.elements = const [],
    this.existingFlows = const [],
    this.coveredConditions = const [],
    this.knownScreens = const [],
    this.knownElements = const [],
    this.fixtures = const [],
  });

  final String appId;
  final String screen;

  /// The steps of an existing flow that reaches [screen], as YAML.
  ///
  /// Supplied verbatim so a proposal can copy navigation that is known
  /// to work. Handing over a flow *path* instead invited the model to
  /// paste it into the `flow:` name field, which is how the first
  /// generated batch came out named after a file.
  final String entryFlow;

  /// Every semantic id in the application, not just this screen's.
  ///
  /// Validation needs the wider set, because a scenario has to
  /// navigate: it taps `home.open_product` on the way to the product
  /// screen. Checking against [elements] alone rejected every correct
  /// proposal for doing exactly what it was told to do.
  final List<String> knownElements;

  /// Every screen id the application actually has.
  ///
  /// Without this a proposal cheerfully expects `product_details` when
  /// the real id is `/product/details`. That parses, so the syntax gate
  /// passes it, and it fails only once someone runs it on a device.
  final List<String> knownScreens;

  /// A real response, which is a better schema than a schema: it shows
  /// field names, types and plausible values at once.
  final Map<String, Object?> apiSample;

  final List<String> elements;
  final List<String> existingFlows;

  /// Conditions the rules already assert, so the model does not propose
  /// what is already covered.
  final List<String> coveredConditions;

  /// The API states that can actually be arranged.
  ///
  /// Without this the first real batch proposed `api_404_not_found`,
  /// `api_timeout` and `empty_highlights_list` - each declaring a
  /// precondition nothing could set up, and one of them naming a field
  /// the API does not have. They parsed, they referenced real ids, and
  /// approving any of them would have added a test that runs against the
  /// default state under an edge-case name.
  final List<String> fixtures;
}

/// A scenario the model proposed and the engine accepted.
@immutable
class ProposedScenario {
  const ProposedScenario({
    required this.name,
    required this.rationale,
    required this.flowYaml,
    required this.flow,
    this.category = 'unspecified',
    this.precondition,
    this.confidence,
  });

  final String name;
  final String category;
  final String rationale;

  /// The state the scenario needs, in words.
  ///
  /// Prose alongside the flow's machine-readable `fixture:`, not instead
  /// of it: the fixture arranges the state and this explains it to
  /// whoever reviews the proposal. A scenario with neither is rejected,
  /// because it would test the default state under an edge-case name.
  final String? precondition;

  final double? confidence;

  /// The flow file exactly as it will be written.
  final String flowYaml;

  /// The same text, parsed - so it is known to be valid before it is
  /// offered to anyone.
  final TestFlow flow;
}

/// A scenario that did not survive validation.
@immutable
class RejectedScenario {
  const RejectedScenario({required this.name, required this.reason});

  final String name;
  final String reason;
}

/// The result of asking for scenarios.
sealed class GenerationOutcome {
  const GenerationOutcome();
}

/// The model answered; these survived validation and these did not.
final class GenerationReady extends GenerationOutcome {
  const GenerationReady({required this.scenarios, required this.rejected});

  final List<ProposedScenario> scenarios;
  final List<RejectedScenario> rejected;
}

/// Nothing could be produced. Never an error: proposing tests is an
/// optional convenience, and a provider outage is not a test failure.
final class GenerationUnavailable extends GenerationOutcome {
  const GenerationUnavailable(this.reason);

  final String reason;
}

/// Proposes edge-case scenarios for a screen.
///
/// Everything it produces is **inert**. The flow is stamped
/// `status: proposed` by this class rather than by the model, and the
/// runner refuses to execute a proposed flow - so a generated scenario
/// cannot become a running test without a person editing the file.
///
/// That is the shape the rest of the platform already uses: AI mapping
/// suggestions land under `suggested:` and stay there until promoted by
/// hand. A generator that could write a runnable test would be a way
/// for a model to decide what "correct" means.
class TestGenerator {
  const TestGenerator(this.client);

  final LlmClient client;

  static const String _system = '''
You propose additional test scenarios for a Flutter screen, in a small
YAML flow language.

What you write is a PROPOSAL. A person reviews it before it ever runs,
and every flow you write is marked as proposed regardless of what you
put in it. Do not try to mark anything approved.

A flow may carry a `fixture:` line above `steps:`, naming the API state
it needs. Use only these steps, exactly as named:
  - launchApp
  - waitForSettle
  - tap:            { id: <semantic id> }
  - input:          { id: <semantic id>, value: <text> }
  - back
  - expectScreen:   { id: <screen id> }
  - expectElement:  { id: <semantic id>, present|enabled|visible: true|false }
  - expectElement:  { id: <semantic id>, textContains: <substring> }
  - validateScreen
  - screenshot:     { name: <file name> }

There are no other steps.

Prefer `validateScreen` - it already compares the API against the UI,
applies the screen's rules, checks the design and compares the
screenshot. Use `expectElement` only for what a mapping cannot say,
which in practice means error and empty states: with an error fixture
every mapped element is legitimately absent, so `validateScreen` alone
would report the correct screen as broken.

Use only the semantic ids you were given, and only the screen ids in
"screenIdsThatExist" - copied character for character, leading slash
included. An id you invent makes the scenario useless.

Copy the navigation from "stepsThatReachIt" rather than inventing a
way to the screen.

"flow:" must be exactly the scenario's "name". It is a name, not a
path.

Propose scenarios that the existing flows and rules do NOT already
cover. Aim at the states a response can be in and the ways it can
fail: an unavailable item, a zero or missing value, a discount present
and absent, an empty list, a 404, a 500, a timeout, a malformed body.

Every scenario must say what API state it needs, and it must be a
state that can actually be arranged:

  * Put `fixture: <name>` in the flow, choosing a name from
    "fixturesThatExist" - copied character for character. That is the
    scenario the mock API will serve.
  * Also fill in "precondition" with what that fixture does, in words.

If no fixture in the list produces the state you have in mind, do not
invent one: propose a different scenario, or describe the state in
"precondition" and leave `fixture:` out. A scenario naming a fixture
that does not exist is rejected.

Reply with a JSON object only:
{
  "scenarios": [
    {
      "name": "snake_case_name",
      "category": "api-state|error|boundary|navigation",
      "rationale": "what this would catch that nothing else does",
      "precondition": "the state it needs",
      "confidence": 0.0,
      "flow": "appId: ...\\nflow: ...\\nsteps:\\n  - launchApp\\n"
    }
  ]
}
''';

  Future<GenerationOutcome> propose({
    required GenerationEvidence evidence,
  }) async {
    final LlmCompletion completion;
    try {
      completion = await client.complete(
        LlmPrompt(
          system: _system,
          user: jsonEncode(_brief(evidence)),
          jsonMode: true,
        ),
      );
    } on LlmException catch (error) {
      return GenerationUnavailable('${client.describe}: ${error.message}');
    } catch (error) {
      return GenerationUnavailable('${client.describe}: $error');
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(_unwrap(completion.content)) as Map)
          .cast<String, Object?>();
    } on FormatException catch (error) {
      return GenerationUnavailable(
        '${client.describe} did not return usable JSON: ${error.message}',
      );
    } on TypeError {
      return GenerationUnavailable(
        '${client.describe} returned JSON that was not an object',
      );
    }

    final accepted = <ProposedScenario>[];
    final rejected = <RejectedScenario>[];
    final taken = {...evidence.existingFlows};

    for (final raw in (decoded['scenarios'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final scenario = raw.cast<String, Object?>();
      final name = (scenario['name'] ?? 'unnamed').toString();

      if (taken.contains(name)) {
        // Overwriting a reviewed test with an unreviewed one is the
        // worst outcome available here.
        rejected.add(
          RejectedScenario(
            name: name,
            reason: 'a flow named "$name" already exists',
          ),
        );
        continue;
      }

      final yaml = _asProposed(
        scenario['flow']?.toString() ?? '',
        name: name,
      );

      final TestFlow parsed;
      try {
        parsed = TestFlow.parse(yaml, source: '$name.yaml');
      } on FlowFormatException catch (error) {
        // Validated here rather than when someone tries to run it. A
        // generated file that breaks the suite is worse than no file.
        rejected.add(
          RejectedScenario(name: name, reason: error.message),
        );
        continue;
      }

      // Parsing proves the syntax, not the sense. A flow expecting
      // `product_details` when the id is `/product/details` parses
      // perfectly and fails only once someone runs it on a device.
      final unknown = _unknownReferences(parsed, evidence);
      if (unknown != null) {
        rejected.add(RejectedScenario(name: name, reason: unknown));
        continue;
      }

      final precondition = scenario['precondition']?.toString().trim();
      final unstageable = _unstageable(parsed, evidence, precondition);
      if (unstageable != null) {
        rejected.add(RejectedScenario(name: name, reason: unstageable));
        continue;
      }

      taken.add(name);
      accepted.add(
        ProposedScenario(
          name: name,
          category: (scenario['category'] ?? 'unspecified').toString(),
          rationale: (scenario['rationale'] ?? '').toString(),
          precondition: scenario['precondition']?.toString(),
          confidence: scenario['confidence'] is num
              ? (scenario['confidence']! as num).toDouble().clamp(0.0, 1.0)
              : null,
          flowYaml: yaml,
          flow: parsed,
        ),
      );
    }

    return GenerationReady(scenarios: accepted, rejected: rejected);
  }

  /// Why this scenario could never be staged, or null if it can be.
  ///
  /// Two failures, both seen in the first real batch: naming a fixture
  /// that does not exist, and naming none while describing a state that
  /// would need one. Either produces a file that looks like a test and
  /// exercises the default state.
  static String? _unstageable(
    TestFlow flow,
    GenerationEvidence evidence,
    String? precondition,
  ) {
    final fixture = flow.fixture;

    if (fixture != null && !evidence.fixtures.contains(fixture)) {
      return 'needs the API state "$fixture", which does not exist. '
          'Available: ${evidence.fixtures.isEmpty ? '(none)' : evidence.fixtures.join(', ')}';
    }

    if (fixture == null && (precondition == null || precondition.isEmpty)) {
      return 'says nothing about the API state it needs, so running it '
          'would test the default state under this name';
    }

    return null;
  }

  /// Names any screen or element the flow refers to that does not
  /// exist, or null when everything checks out.
  ///
  /// Parsing proves syntax, not sense. A flow expecting
  /// `product_details` when the id is `/product/details` parses
  /// perfectly and fails only once someone runs it on a device - which
  /// is exactly the kind of waste a proposal is supposed to save.
  static String? _unknownReferences(
    TestFlow flow,
    GenerationEvidence evidence,
  ) {
    final screens = {...evidence.knownScreens, evidence.screen};
    // The wider set: a scenario legitimately taps ids belonging to the
    // screens it passes through on the way.
    final elements = {...evidence.knownElements, ...evidence.elements};

    for (final step in flow.steps) {
      switch (step) {
        case ExpectScreenStep(:final screenId):
          if (!screens.contains(screenId)) {
            return 'expects screen "$screenId", which does not exist. '
                'Known: ${(screens.toList()..sort()).join(', ')}';
          }
        case TapStep(:final elementId):
          if (elements.isNotEmpty && !elements.contains(elementId)) {
            return 'taps "$elementId", which is not a semantic id here';
          }
        case ExpectElementStep(:final elementId):
          if (elements.isNotEmpty && !elements.contains(elementId)) {
            return 'asserts on "$elementId", which is not a semantic id '
                'here';
          }
        case InputStep(:final elementId):
          if (elements.isNotEmpty && !elements.contains(elementId)) {
            return 'types into "$elementId", which is not a semantic id '
                'here';
          }
        default:
          break;
      }
    }
    return null;
  }

  /// Forces `status: proposed` and the agreed name onto a generated
  /// flow.
  ///
  /// Applied here rather than requested in the prompt, because asking
  /// politely is not a control. The name matters as much as the status:
  /// the first real batch came back with `flow:` set to the file path
  /// of the example it had been shown.
  static String _asProposed(String yaml, {required String name}) {
    final withoutStatus = yaml
        .split('\n')
        .map((line) =>
            RegExp(r'^\s*flow\s*:').hasMatch(line) ? 'flow: $name' : line)
        .where((line) => !RegExp(r'^\s*status\s*:').hasMatch(line))
        .join('\n');

    final lines = withoutStatus.split('\n');
    final stepsAt = lines.indexWhere((l) => RegExp(r'^\s*steps\s*:').hasMatch(l));

    // Before `steps:`, so the mark is visible at the top of the file
    // rather than buried under the scenario.
    final at = stepsAt == -1 ? lines.length : stepsAt;
    return [
      ...lines.take(at),
      'status: proposed',
      ...lines.skip(at),
    ].join('\n');
  }

  Map<String, Object?> _brief(GenerationEvidence evidence) => {
        'appId': evidence.appId,
        'screen': evidence.screen,
        'stepsThatReachIt': evidence.entryFlow,
        'screenIdsThatExist': evidence.knownScreens,
        'apiResponseSample': evidence.apiSample,
        'semanticIdsAvailable': evidence.elements,
        'flowsThatAlreadyExist': evidence.existingFlows,
        'conditionsAlreadyAssertedByRules': evidence.coveredConditions,
        'fixturesThatExist': evidence.fixtures,
      };

  static String _unwrap(String content) {
    final text = content.trim();
    if (!text.startsWith('```')) return text;

    final firstNewline = text.indexOf('\n');
    if (firstNewline == -1) return text;

    final body = text.substring(firstNewline + 1);
    final closing = body.lastIndexOf('```');
    return (closing == -1 ? body : body.substring(0, closing)).trim();
  }
}
