import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../validation/api_expectation.dart';
import '../validation/response_source.dart';
import 'steps.dart';

/// A flow file could not be read.
///
/// Always names the file and, where the YAML parser gives a span, the
/// line. A typo'd step that silently does nothing is the worst outcome
/// available: the run reports green having tested nothing.
@immutable
class FlowFormatException implements Exception {
  const FlowFormatException(this.source, this.message, {this.line});

  final String source;
  final String message;
  final int? line;

  @override
  String toString() =>
      'FlowFormatException in $source'
      '${line == null ? '' : ' at line $line'}: $message';
}

/// Whether a flow has been accepted as a test.
enum FlowStatus {
  /// Written or reviewed by a person. Runs normally.
  approved('approved'),

  /// Generated, and inert until promoted. The runner refuses it.
  proposed('proposed');

  const FlowStatus(this.wire);

  final String wire;
}

/// A parsed test flow.
@immutable
class TestFlow {
  const TestFlow({
    required this.appId,
    required this.name,
    required this.steps,
    this.status = FlowStatus.approved,
    this.fixture,
  });

  final String appId;
  final String name;
  final List<Step> steps;

  /// The named API state this flow needs, if any.
  ///
  /// A flow that asserts "the screen shows Out of stock" is only a test
  /// when the API actually says the product is unavailable. Naming the
  /// scenario here makes that arrangement part of the flow rather than
  /// something a person has to remember to do first - and lets the
  /// runner refuse a flow whose scenario does not exist, instead of
  /// running it against whatever happened to be loaded.
  ///
  /// Null means "whatever the runner was given", which is the right
  /// default for a flow that does not care.
  final String? fixture;

  /// Whether a person has accepted this flow as a test.
  final FlowStatus status;

  /// A generated scenario nobody has reviewed yet.
  ///
  /// The mark lives on the flow rather than on the folder it sits in,
  /// so pointing the runner straight at the file still refuses. An
  /// approval gate that a path can sidestep is not a gate.
  bool get isProposed => status == FlowStatus.proposed;

  static const Set<String> _topLevelKeys = {
    'appId',
    'flow',
    'steps',
    'status',
    'fixture',
  };

  static const Map<String, Set<String>> _stepArguments = {
    'launchApp': {},
    'waitForSettle': {'timeoutMs'},
    'tap': {'id'},
    'input': {'id', 'value'},
    'back': {},
    'expectScreen': {'id', 'timeoutMs'},
    'expectElement': {
      'id',
      'present',
      'enabled',
      'visible',
      'text',
      'textContains',
      'timeoutMs',
    },
    'screenshot': {'name'},
    'expectApi': {
      'endpoint',
      'status',
      'occurrence',
      'expect',
      'timeoutMs',
    },
    'validateScreen': {'api', 'ui', 'rules', 'figma', 'visual'},
  };

  factory TestFlow.parse(String yamlText, {required String source}) {
    final YamlNode root;
    try {
      root = loadYamlNode(yamlText);
    } on YamlException catch (error) {
      throw FlowFormatException(source, 'invalid YAML: ${error.message}');
    }

    if (root is! YamlMap) {
      throw FlowFormatException(
        source,
        'expected a mapping at the root with appId, flow and steps',
      );
    }

    for (final key in root.keys) {
      if (!_topLevelKeys.contains(key)) {
        throw FlowFormatException(
          source,
          'unknown key "$key". Known: ${_topLevelKeys.join(', ')}.',
          line: _lineOf(root.nodes[key]),
        );
      }
    }

    final appId = root['appId'];
    if (appId is! String) {
      throw FlowFormatException(source, 'an "appId" is required');
    }

    final rawSteps = root['steps'];
    if (rawSteps is! YamlList || rawSteps.isEmpty) {
      throw FlowFormatException(
        source,
        'a "steps" list with at least one step is required',
      );
    }

    final fixture = root['fixture'];
    if (fixture != null && fixture is! String) {
      throw FlowFormatException(
        source,
        '"fixture" must be the name of a scenario file, as in '
        '`fixture: product_out_of_stock`',
        line: _lineOf(root.nodes['fixture']),
      );
    }

    return TestFlow(
      appId: appId,
      fixture: fixture as String?,
      name: _optionalName(source, root),
      status: _readStatus(source, root['status'], _lineOf(root.nodes['status'])),
      steps: [
        for (final node in rawSteps.nodes) _readStep(source, node),
      ],
    );
  }

  /// Reads `flow:`, the flow's own name.
  ///
  /// Optional, and "unnamed" when it is not given - both of which the
  /// cast this replaces already meant. What it did not mean was
  /// `flow: 123`: that left the parser as a `TypeError`, which no caller
  /// guards, so an ordinary YAML slip exited 255 with a stack trace
  /// while an unknown *key* in the same file exited 1 and named it.
  static String _optionalName(String source, YamlMap root) {
    final value = root['flow'];
    if (value == null) return 'unnamed';
    if (value is! String) {
      throw FlowFormatException(
        source,
        '"flow" must be a name, as in `flow: checkout`',
        line: _lineOf(root.nodes['flow']),
      );
    }
    return value;
  }

  /// Reads `status:`, refusing anything it does not recognise.
  ///
  /// Guessing either way is unacceptable: assuming "approved" would run
  /// something nobody reviewed, and assuming "proposed" would silently
  /// drop a real test from the suite.
  static FlowStatus _readStatus(String source, Object? value, int? line) {
    if (value == null) return FlowStatus.approved;

    for (final status in FlowStatus.values) {
      if (status.wire == value.toString()) return status;
    }

    throw FlowFormatException(
      source,
      'unknown status "$value". Known: '
      '${FlowStatus.values.map((s) => s.wire).join(', ')}.',
      line: line,
    );
  }

  static int? _lineOf(YamlNode? node) =>
      node == null ? null : node.span.start.line + 1;

  static Step _readStep(String source, YamlNode node) {
    // A bare step: `- launchApp`
    if (node is YamlScalar) {
      final name = node.value;
      if (name is! String) {
        throw FlowFormatException(source, 'a step must be named',
            line: _lineOf(node));
      }
      return _build(source, name, const {}, node);
    }

    // A step with arguments: `- tap: { id: x }`
    if (node is YamlMap) {
      if (node.length != 1) {
        throw FlowFormatException(
          source,
          'each list entry must be a single step',
          line: _lineOf(node),
        );
      }
      final name = node.keys.first;
      if (name is! String) {
        throw FlowFormatException(source, 'a step must be named',
            line: _lineOf(node));
      }
      final rawArgs = node.values.first;
      final args = rawArgs is YamlMap
          ? rawArgs.cast<String, Object?>()
          : const <String, Object?>{};
      return _build(source, name, args, node);
    }

    throw FlowFormatException(source, 'unreadable step',
        line: _lineOf(node));
  }

  static Step _build(
    String source,
    String name,
    Map<String, Object?> args,
    YamlNode node,
  ) {
    final allowed = _stepArguments[name];
    if (allowed == null) {
      final nearest = _nearest(name, _stepArguments.keys);
      throw FlowFormatException(
        source,
        'unknown step "$name"'
        '${nearest == null ? '' : '. Did you mean "$nearest"?'} '
        'Known steps: ${_stepArguments.keys.join(', ')}.',
        line: _lineOf(node),
      );
    }

    for (final key in args.keys) {
      if (!allowed.contains(key)) {
        throw FlowFormatException(
          source,
          '"$name" has no argument "$key". '
          '${allowed.isEmpty ? 'It takes none.' : 'Takes: ${allowed.join(', ')}.'}',
          line: _lineOf(node),
        );
      }
    }

    String requireString(String key) {
      final value = args[key];
      if (value is! String) {
        throw FlowFormatException(
          source,
          '"$name" needs a "$key"',
          line: _lineOf(node),
        );
      }
      return value;
    }

    /// Tri-state: absent means "decide automatically", not "off".
    bool? optionalFlag(String key) =>
        args.containsKey(key) ? args[key] == true : null;

    /// An assertion's expected value. Absent means "do not assert this",
    /// which is not the same as asserting false - so a mistyped value
    /// must not quietly become one.
    bool? optionalBool(String key) {
      if (!args.containsKey(key)) return null;
      final value = args[key];
      if (value is! bool) {
        throw FlowFormatException(
          source,
          '"$name" needs true or false for "$key", not "$value"',
          line: _lineOf(node),
        );
      }
      return value;
    }

    /// The same, for an assertion's expected text.
    ///
    /// Written as a cast until now, so `text: 12` left the parser as a
    /// `TypeError` rather than a [FlowFormatException] - which is not
    /// what any caller guards, so the command exited 255 with a stack
    /// trace. Absent and an explicit `null` still both mean "do not
    /// assert this", exactly as the cast did.
    String? optionalString(String key) {
      final value = args[key];
      if (value == null) return null;
      if (value is! String) {
        throw FlowFormatException(
          source,
          '"$name" needs text for "$key", not "$value"',
          line: _lineOf(node),
        );
      }
      return value;
    }

    /// `timeoutMs`, whose absence means the step's own default.
    ///
    /// `timeoutMs: "5s"` is the natural way to get this wrong, and it
    /// was the same unguarded cast. A number is required rather than
    /// parsed from text: inventing a duration from a string nobody
    /// agreed the format of is how two files start meaning different
    /// things by the same value.
    Duration timeout(int fallback) {
      final value = args['timeoutMs'];
      if (value == null) return Duration(milliseconds: fallback);
      if (value is! num) {
        throw FlowFormatException(
          source,
          '"$name" needs a whole number of milliseconds for "timeoutMs", '
          'not "$value"',
          line: _lineOf(node),
        );
      }
      return Duration(milliseconds: value.toInt());
    }

    return switch (name) {
      'launchApp' => const LaunchAppStep(),
      'back' => const BackStep(),
      'waitForSettle' => WaitForSettleStep(timeout: timeout(10000)),
      'tap' => TapStep(requireString('id')),
      'input' => InputStep(
          elementId: requireString('id'),
          value: requireString('value'),
        ),
      'expectScreen' => ExpectScreenStep(
          requireString('id'),
          timeout: timeout(5000),
        ),
      'expectElement' => ExpectElementStep(
          elementId: requireString('id'),
          present: optionalBool('present'),
          enabled: optionalBool('enabled'),
          visible: optionalBool('visible'),
          text: optionalString('text'),
          textContains: optionalString('textContains'),
          timeout: timeout(5000),
        ),
      'screenshot' => ScreenshotStep(requireString('name')),
      'expectApi' => _readExpectApi(source, args, node),
      'validateScreen' => ValidateScreenStep(
          api: optionalFlag('api'),
          ui: optionalFlag('ui'),
          rules: optionalFlag('rules'),
          figma: optionalFlag('figma'),
          visual: optionalFlag('visual'),
        ),
      _ => throw FlowFormatException(source, 'unhandled step "$name"'),
    };
  }

  static const Set<String> _expectationKeys = {
    'path',
    'equals',
    'count',
    'present',
  };

  /// Reads an `expectApi:` step.
  ///
  /// Every refusal here happens before the app is launched. The failure
  /// this guards against is a step that parses and asserts nothing -
  /// the same defect as the `api:` key that was read and then ignored
  /// from Phase 4 to the external-application milestone.
  static ExpectApiStep _readExpectApi(
    String source,
    Map<String, Object?> args,
    YamlNode node,
  ) {
    Never fail(String message) =>
        throw FlowFormatException(source, message, line: _lineOf(node));

    final raw = args['endpoint'];
    if (raw is! String) {
      fail('"expectApi" needs an "endpoint", as in '
          '`endpoint: GET /api/orders`');
    }
    final endpoint = ApiEndpoint.tryParse(raw);
    if (endpoint == null) {
      fail('"$raw" is not an endpoint. Write METHOD /path, as in '
          '`GET /api/orders` - a path segment may be `*`');
    }

    // Required, deliberately. A step that asserts an endpoint was called
    // and says nothing about the answer passes against a 500, and a
    // screen rendered from a failed request photographs perfectly well.
    final status = args['status'];
    if (status is! int || status < 100 || status > 599) {
      fail('"expectApi" needs a "status" - the HTTP status the '
          'application must have received. Without one this step would '
          'pass against a 500');
    }

    var occurrence = ResponseOccurrence.only;
    final rawOccurrence = args['occurrence'];
    if (rawOccurrence != null) {
      final parsed = ResponseOccurrence.tryParse(rawOccurrence.toString());
      if (parsed == null) {
        fail('unknown occurrence "$rawOccurrence". Known: '
            '${ResponseOccurrence.values.map((o) => o.wire).join(', ')}.');
      }
      occurrence = parsed;
    }

    final expectations = <ApiExpectation>[];
    final rawExpect = args['expect'];
    if (rawExpect != null) {
      if (rawExpect is! List) {
        fail('"expect" must be a list of field assertions, each with a '
            '"path"');
      }
      for (final item in rawExpect) {
        if (item is! Map) {
          fail('each "expect" entry must be a mapping with a "path"');
        }
        final entry = item.cast<Object?, Object?>().map(
              (key, value) => MapEntry(key.toString(), value),
            );

        for (final key in entry.keys) {
          if (!_expectationKeys.contains(key)) {
            fail('an "expect" entry has no key "$key". Takes: '
                '${_expectationKeys.join(', ')}.');
          }
        }

        final path = entry['path'];
        if (path is! String || path.trim().isEmpty) {
          fail('every "expect" entry needs a "path" into the response '
              'body, as in `path: data.orders.0.status`');
        }

        final named = [
          for (final key in const ['equals', 'count', 'present'])
            if (entry.containsKey(key)) key,
        ];
        if (named.isEmpty) {
          fail('"$path" asserts nothing. Add one of "equals", "count" or '
              '"present" - a path on its own reads like a check and is '
              'not one');
        }
        if (named.length > 1) {
          fail('"$path" sets ${named.join(' and ')}, so which one decides '
              'the verdict has no defensible answer. Use one');
        }

        final count = entry['count'];
        if (entry.containsKey('count') && (count is! int || count < 0)) {
          fail('"count" on "$path" must be a whole number of entries, not '
              '"$count"');
        }

        final present = entry['present'];
        if (entry.containsKey('present') && present is! bool) {
          fail('"present" on "$path" must be true or false, not "$present"');
        }

        expectations.add(
          ApiExpectation(
            path: path,
            // Kept as YAML read it. Coercing to a string would make
            // `equals: 3` fail against a correct numeric response.
            equals: entry.containsKey('equals')
                ? _plain(entry['equals'])
                : null,
            count: count as int?,
            present: present as bool?,
          ),
        );
      }
    }

    return ExpectApiStep(
      endpoint: endpoint,
      status: status,
      occurrence: occurrence,
      expectations: expectations,
      // The same field as the steps above, in a function of its own and
      // so out of reach of their closure. Guarded the same way: a
      // `timeoutMs` that is not a number is a file to correct, not a
      // `TypeError` for the caller to fail to catch.
      timeout: _timeout(source, args, node, 'expectApi', 10000),
    );
  }

  /// `timeoutMs` for a step parsed outside [_readStep]'s closures.
  static Duration _timeout(
    String source,
    Map<String, Object?> args,
    YamlNode node,
    String name,
    int fallback,
  ) {
    final value = args['timeoutMs'];
    if (value == null) return Duration(milliseconds: fallback);
    if (value is! num) {
      throw FlowFormatException(
        source,
        '"$name" needs a whole number of milliseconds for "timeoutMs", '
        'not "$value"',
        line: _lineOf(node),
      );
    }
    return Duration(milliseconds: value.toInt());
  }

  /// Unwraps whatever the YAML parser handed back into plain Dart.
  static Object? _plain(Object? value) => switch (value) {
        final YamlScalar scalar => scalar.value,
        _ => value,
      };

  /// Cheap nearest-match, purely to make a typo obvious.
  static String? _nearest(String name, Iterable<String> candidates) {
    String? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      var score = 0;
      for (var i = 0; i < name.length && i < candidate.length; i++) {
        if (name[i] == candidate[i]) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore >= 3 ? best : null;
  }
}
