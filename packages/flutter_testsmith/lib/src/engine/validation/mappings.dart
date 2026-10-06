import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../secrets/secret_ref.dart';
import '../visual/visual_validator.dart';
import 'api_source.dart';
import 'figma_source.dart';
import 'quiescence.dart';
import 'response_source.dart';
import 'figma_tolerances.dart';
import 'transformations.dart';

/// A mappings file could not be read.
///
/// Always names the file and the offending key, and suggests the nearest
/// valid one where it can: a typo'd key that silently does nothing is
/// worse than no file at all, because the run reports green while
/// checking nothing.
@immutable
class MappingsFormatException implements Exception {
  const MappingsFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'MappingsFormatException in $source: $message';
}

/// One API field bound to one UI element.
@immutable
class Mapping {
  const Mapping({
    required this.target,
    required this.source,
    this.property = 'text',
    this.transformation = 'identity',
    this.confidence,
  });

  /// Semantic id of the UI element.
  final String target;

  /// Dotted path into the response, as written (`response.price`).
  final String source;

  /// Which property of the element to compare. Defaults to its text.
  final String property;

  final String transformation;

  /// Set only on AI suggestions, never on an active mapping.
  final double? confidence;

  /// [source] without the readability prefix.
  String get responsePath =>
      source.startsWith('response.') ? source.substring(9) : source;

  @override
  String toString() =>
      'Mapping($source -> $target.$property via $transformation)';
}

/// What must hold when a rule's condition is true.
@immutable
class Expectation {
  const Expectation({
    required this.element,
    required this.property,
    required this.equals,
  });

  final String element;
  final String property;
  final Object? equals;

  @override
  String toString() => '$element.$property == $equals';
}

/// A conditional business rule.
@immutable
class Rule {
  const Rule({required this.condition, required this.expectations});

  final String condition;
  final List<Expectation> expectations;
}

/// A parsed `field op value` test over the API response.
///
/// Deliberately tiny. This is a rules language, not a scripting
/// language: anything it cannot express belongs in a test, where it can
/// be read.
@immutable
class Condition {
  const Condition._(this.field, this.operator, this.value, this.source);

  final String field;
  final String operator;
  final Object? value;
  final String source;

  static final RegExp _pattern =
      RegExp(r'^\s*([\w.]+)\s*(==|!=|>=|<=|>|<)\s*(.+?)\s*$');

  static Condition parse(String source) {
    final match = _pattern.firstMatch(source);
    if (match == null) {
      throw FormatException(
        'Not a condition. Expected `field == value`, with one of '
        '== != > < >= <=',
        source,
      );
    }
    return Condition._(
      match.group(1)!,
      match.group(2)!,
      _literal(match.group(3)!),
      source,
    );
  }

  static Object? _literal(String raw) {
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    if (raw == 'null') return null;
    final number = num.tryParse(raw);
    if (number != null) return number;
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw.substring(1, raw.length - 1);
    }
    return raw;
  }

  /// Evaluates against a response field reader.
  ///
  /// A field the response does not carry makes the condition false
  /// rather than an error: a rule about an absent field simply does not
  /// apply to this response.
  bool evaluate(Object? Function(String field) read) {
    final actual = read(field);
    if (actual == null && value != null) return false;

    switch (operator) {
      case '==':
        return actual == value;
      case '!=':
        return actual != value;
    }

    final expected = value;
    if (actual is! num || expected is! num) return false;
    return switch (operator) {
      '>' => actual > expected,
      '<' => actual < expected,
      '>=' => actual >= expected,
      '<=' => actual <= expected,
      _ => false,
    };
  }

  @override
  String toString() => source;
}

/// The human-owned description of how one screen relates to its API.
@immutable
class MappingsFile {
  const MappingsFile({
    required this.screen,
    required this.mappings,
    required this.rules,
    required this.suggested,
    this.api,
    this.usesResponseFrom,
    this.apiSource,
    this.figmaSource,
    this.figma = FigmaTolerances.defaults,
    this.visual = VisualCheckConfig.defaults,
    this.quiescence = QuiescencePolicy.none,
  });

  final String screen;

  /// The endpoint this screen calls itself.
  final String? api;

  /// Where this screen's data came from, when it did not fetch it.
  ///
  /// Null means the screen is validated against its own exchanges, as
  /// it always was. Declaring this is the only way a screen may look
  /// outside itself - there is deliberately no automatic fallback.
  final ResponseSource? usesResponseFrom;
  /// How to fetch this screen's response when the capture cannot supply
  /// it.
  ///
  /// Null means captured traffic is the only source, exactly as before.
  /// Even when set, the capture is still preferred - this is consulted
  /// only when the required captured response is unavailable, and never
  /// when it is ambiguous.
  final ApiSource? apiSource;

  /// The design this screen is validated against, declared here rather
  /// than pulled to disk beforehand.
  ///
  /// Null falls back to `<project>/figma/<screen>.json`.
  final FigmaSource? figmaSource;

  final List<Mapping> mappings;
  final List<Rule> rules;

  /// Thresholds for this screen's Figma comparison.
  ///
  /// Per screen rather than global: a dense form legitimately needs a
  /// tighter position tolerance than a hero banner, and one global
  /// number would be tuned to whichever screen complained loudest.
  final FigmaTolerances figma;

  /// Thresholds and ignore regions for this screen's visual check.
  final VisualCheckConfig visual;

  /// The animations this screen expects to run for ever.
  ///
  /// Empty for every screen that does not mention it, which is what
  /// makes this addition invisible to screens that already settled.
  final QuiescencePolicy quiescence;

  /// AI proposals. Parsed, kept, and **never applied**.
  ///
  /// Promotion into [mappings] is a manual edit. See ARCHITECTURE 10.6.
  final List<Mapping> suggested;

  Mapping? mappingFor(String target) {
    for (final mapping in mappings) {
      if (mapping.target == target) return mapping;
    }
    return null;
  }

  static const Set<String> _topLevelKeys = {
    'screen',
    'api',
    'usesResponseFrom',
    'apiSource',
    'figmaSource',
    'mappings',
    'rules',
    'suggested',
    'figma',
    'visual',
    'quiescence',
  };
  static const Set<String> _mappingKeys = {
    'target',
    'source',
    'property',
    'transformation',
    'confidence',
  };
  static const Set<String> _ruleKeys = {'condition', 'expectations'};
  static const Set<String> _expectationKeys = {'element', 'property', 'equals'};

  factory MappingsFile.parse(
    String yamlText, {
    required String source,
    TransformationRegistry? registry,
  }) {
    final transformations = registry ?? TransformationRegistry.defaults();

    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      throw MappingsFormatException(source, 'invalid YAML: ${error.message}');
    }

    if (loaded is! Map) {
      throw MappingsFormatException(source, 'expected a mapping at the root');
    }
    final root = Map<String, Object?>.from(loaded.cast<String, Object?>());

    _rejectUnknownKeys(source, root.keys, _topLevelKeys, 'top-level key');

    final screen = root['screen'];
    if (screen is! String) {
      throw MappingsFormatException(source, 'a "screen" is required');
    }

    return MappingsFile(
      screen: screen,
      api: _optionalString(source, root['api'], 'api'),
      usesResponseFrom: _readResponseSource(source, root['usesResponseFrom']),
      apiSource: _readApiSource(source, root['apiSource']),
      figmaSource: _readFigmaSource(source, root['figmaSource']),
      mappings: _readMappings(
        source,
        root['mappings'],
        transformations,
        allowConfidence: false,
      ),
      rules: _readRules(source, root['rules']),
      figma: _readFigma(source, root['figma']),
      visual: _readVisual(source, root['visual']),
      quiescence: _readQuiescence(source, root['quiescence']),
      suggested: _readMappings(
        source,
        root['suggested'],
        transformations,
        allowConfidence: true,
      ),
    );
  }


  static const Set<String> _apiSourceKeys = {
    'baseUrl',
    'method',
    'endpoint',
    'token',
    'headers',
    'query',
    'body',
  };

  static const Set<String> _figmaSourceKeys = {'url', 'token', 'mapping'};

  /// Reads `apiSource:`.
  ///
  /// Every refusal happens before anything is launched or requested. A
  /// block that parses and fetches nothing would be the same defect as
  /// the `api:` key that was read and then ignored from Phase 4 onward.
  static ApiSource? _readApiSource(String source, Object? node) {
    if (node == null) return null;
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"apiSource" must be a mapping with baseUrl, method and endpoint',
      );
    }
    final map = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    _rejectUnknownKeys(source, map.keys, _apiSourceKeys, 'apiSource key');

    String require(String key) {
      final value = map[key];
      if (value is! String || value.trim().isEmpty) {
        throw MappingsFormatException(
          source,
          '"apiSource" needs a "$key", as in ${_apiSourceExample(key)}',
        );
      }
      return value.trim();
    }

    SecretRef? token;
    final rawToken = map['token'];
    if (rawToken != null) {
      // Throws when given a literal, which is the point: a credential
      // written into a mappings file is a credential in git.
      try {
        token = SecretRef.parse('$rawToken', source: source);
      } on SecretRefFormatException catch (error) {
        throw MappingsFormatException(source, error.message);
      }
    }

    return ApiSource(
      baseUrl: require('baseUrl'),
      method: require('method').toUpperCase(),
      endpoint: require('endpoint'),
      token: token,
      headers: _stringMap(source, map['headers'], 'headers'),
      query: _stringMap(source, map['query'], 'query'),
      body: _optionalString(source, map['body'], 'body'),
    );
  }

  static String _apiSourceExample(String key) => switch (key) {
        'baseUrl' => '`baseUrl: env:EXAMPLE_API_BASE`',
        'method' => '`method: GET`',
        'endpoint' => '`endpoint: /products/123`',
        _ => '`$key: ...`',
      };

  static Map<String, String> _stringMap(
    String source,
    Object? node,
    String name,
  ) {
    if (node == null) return const {};
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"$name" must be a mapping of names to values',
      );
    }
    return {
      for (final entry in node.entries) entry.key.toString(): '${entry.value}',
    };
  }

  /// An optional [key] that must be text when it is given at all.
  ///
  /// The same shape as the guarded `screen` above, for the fields that
  /// were written as casts instead. A `TypeError` is not a
  /// [MappingsFormatException], so `api: 123` went straight through the
  /// guard every call site has had since `be9fca3` and the command
  /// exited 255 with a stack trace - a file somebody has to correct,
  /// reported as a defect in the tool. An unknown *key* in the same file
  /// has always exited 1 and said which file.
  ///
  /// Absent and an explicit `null` both still mean "not given", exactly
  /// as the cast did. Only the wrong type is new.
  static String? _optionalString(String source, Object? value, String key) {
    if (value == null) return null;
    if (value is! String) {
      throw MappingsFormatException(source, '"$key" must be text');
    }
    return value;
  }

  /// The same, for a field that must be a number.
  static double? _optionalNumber(String source, Object? value, String key) {
    if (value == null) return null;
    if (value is! num) {
      throw MappingsFormatException(source, '"$key" must be a number');
    }
    return value.toDouble();
  }

  /// Reads `figmaSource:`.
  static FigmaSource? _readFigmaSource(String source, Object? node) {
    if (node == null) return null;
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"figmaSource" must be a mapping with url, token and mapping',
      );
    }
    final map = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    _rejectUnknownKeys(source, map.keys, _figmaSourceKeys, 'figmaSource key');

    String require(String key) {
      final value = map[key];
      if (value is! String || value.trim().isEmpty) {
        throw MappingsFormatException(source, '"figmaSource" needs a "$key"');
      }
      return value.trim();
    }

    final url = require('url');
    if (!url.contains('node-id')) {
      throw MappingsFormatException(
        source,
        'the figmaSource url has no node-id. Open the frame in Figma and '
        'copy the link to it, which includes node-id=...',
      );
    }

    // Read before the token so a file missing both names the mapping
    // first - the one a person is more likely to have forgotten.
    final mappingPath = require('mapping');

    final SecretRef token;
    try {
      token = SecretRef.parse('${map['token']}', source: source);
    } on SecretRefFormatException catch (error) {
      throw MappingsFormatException(source, error.message);
    }

    return FigmaSource(url: url, token: token, mappingPath: mappingPath);
  }


  /// Reads the `quiescence:` section.
  ///
  /// Strict at parse time for the same reason `usesResponseFrom` is: a
  /// declaration that silently did nothing would leave a screen either
  /// hanging for ever or - far worse - excusing an animation nobody
  /// meant to excuse. Every complaint here names the file and the key.
  /// Reads `quiescence:` through the one shared parser.
  ///
  /// Delegated rather than implemented here, so a mappings file and an
  /// auth file cannot drift into two dialects of the same block.
  static QuiescencePolicy _readQuiescence(String source, Object? node) =>
      QuiescencePolicy.parse(
        node,
        bad: (message) => throw MappingsFormatException(source, message),
      );

  static const Set<String> _sourceKeys = {
    'endpoint',
    'occurrence',
    'capturedOn',
    'maxAgeSeconds',
  };

  /// Reads the `usesResponseFrom:` section.
  ///
  /// Every complaint is a parse error rather than a runtime surprise: a
  /// declaration that silently did nothing would leave a screen
  /// validating against the wrong response, which is the failure this
  /// whole feature exists to remove.
  static ResponseSource? _readResponseSource(String source, Object? node) {
    if (node == null) return null;
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"usesResponseFrom" must be a mapping with an "endpoint"',
      );
    }

    final raw = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    _rejectUnknownKeys(
      source,
      raw.keys,
      _sourceKeys,
      'usesResponseFrom key',
    );

    final endpoint = ApiEndpoint.tryParse(raw['endpoint']?.toString());
    if (endpoint == null) {
      throw MappingsFormatException(
        source,
        '"usesResponseFrom" needs an "endpoint" of the form '
        '"METHOD /path", as in "GET /api/profile/me". '
        'Got: ${raw['endpoint'] ?? '(nothing)'}.',
      );
    }

    final rawOccurrence = raw['occurrence']?.toString();
    final occurrence = rawOccurrence == null
        ? ResponseOccurrence.only
        : ResponseOccurrence.tryParse(rawOccurrence);
    if (occurrence == null) {
      throw MappingsFormatException(
        source,
        'unknown occurrence "$rawOccurrence". Known: '
        '${ResponseOccurrence.values.map((o) => o.wire).join(', ')}. '
        'The default is "only", which refuses to choose between two '
        'matching responses.',
      );
    }

    final rawMaxAge = raw['maxAgeSeconds'];
    if (rawMaxAge != null && (rawMaxAge is! num || rawMaxAge < 0)) {
      throw MappingsFormatException(
        source,
        '"maxAgeSeconds" must be a number of seconds, not "$rawMaxAge"',
      );
    }

    return ResponseSource(
      endpoint: endpoint,
      occurrence: occurrence,
      capturedOn: raw['capturedOn']?.toString(),
      maxAge: rawMaxAge == null
          ? null
          : Duration(seconds: (rawMaxAge as num).round()),
    );
  }

  /// Reads the `figma:` section, restating any complaint in the same
  /// form as every other error from this file.
  static FigmaTolerances _readFigma(String source, Object? node) {
    try {
      return FigmaTolerances.fromYaml(node, source: source);
    } on FormatException catch (error) {
      // Both layers name the file; saying it twice reads like a bug.
      final prefix = '$source: ';
      final message = error.message.startsWith(prefix)
          ? error.message.substring(prefix.length)
          : error.message;
      throw MappingsFormatException(source, message);
    }
  }

  /// Reads the `visual:` section, restating any complaint in the same
  /// form as every other error from this file.
  static VisualCheckConfig _readVisual(String source, Object? node) {
    try {
      return VisualCheckConfig.fromYaml(node, source: source);
    } on FormatException catch (error) {
      final prefix = '$source: ';
      final message = error.message.startsWith(prefix)
          ? error.message.substring(prefix.length)
          : error.message;
      throw MappingsFormatException(source, message);
    }
  }

  static void _rejectUnknownKeys(
    String source,
    Iterable<String> found,
    Set<String> allowed,
    String what,
  ) {
    for (final key in found) {
      if (allowed.contains(key)) continue;
      final nearest = _nearest(key, allowed);
      throw MappingsFormatException(
        source,
        'unknown $what "$key"'
        '${nearest == null ? '' : '. Did you mean "$nearest"?'} '
        'Known: ${allowed.join(', ')}.',
      );
    }
  }

  /// Cheap nearest-match, purely to make a typo obvious.
  static String? _nearest(String key, Set<String> candidates) {
    String? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      var score = 0;
      for (var i = 0; i < key.length && i < candidate.length; i++) {
        if (key[i] == candidate[i]) score++;
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore >= 3 ? best : null;
  }

  static List<Mapping> _readMappings(
    String source,
    Object? raw,
    TransformationRegistry transformations, {
    required bool allowConfidence,
  }) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw MappingsFormatException(source, 'mappings must be a list');
    }

    return [
      for (final entry in raw)
        _readMapping(source, entry, transformations, allowConfidence),
    ];
  }

  static Mapping _readMapping(
    String source,
    Object? raw,
    TransformationRegistry transformations,
    bool allowConfidence,
  ) {
    if (raw is! Map) {
      throw MappingsFormatException(source, 'each mapping must be a map');
    }
    final entry = raw.cast<String, Object?>();
    _rejectUnknownKeys(source, entry.keys, _mappingKeys, 'mapping key');

    final target = entry['target'];
    if (target is! String) {
      throw MappingsFormatException(source, 'a mapping needs a "target"');
    }
    final mappingSource = entry['source'];
    if (mappingSource is! String) {
      throw MappingsFormatException(
        source,
        'mapping "$target" needs a "source"',
      );
    }

    final transformation =
        _optionalString(source, entry['transformation'], 'transformation') ??
            'identity';
    try {
      // Resolved at load so a typo fails the file rather than the run.
      transformations.resolve(transformation);
    } on UnknownTransformationException catch (error) {
      throw MappingsFormatException(source, error.toString());
    }

    return Mapping(
      target: target,
      source: mappingSource,
      property:
          _optionalString(source, entry['property'], 'property') ?? 'text',
      transformation: transformation,
      confidence: allowConfidence
          ? _optionalNumber(source, entry['confidence'], 'confidence')
          : null,
    );
  }

  static List<Rule> _readRules(String source, Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw MappingsFormatException(source, 'rules must be a list');
    }

    return [
      for (final entry in raw) _readRule(source, entry),
    ];
  }

  static Rule _readRule(String source, Object? raw) {
    if (raw is! Map) {
      throw MappingsFormatException(source, 'each rule must be a map');
    }
    final entry = raw.cast<String, Object?>();
    _rejectUnknownKeys(source, entry.keys, _ruleKeys, 'rule key');

    final condition = entry['condition'];
    if (condition is! String) {
      throw MappingsFormatException(source, 'a rule needs a "condition"');
    }
    try {
      Condition.parse(condition);
    } on FormatException catch (error) {
      throw MappingsFormatException(source, error.message);
    }

    final rawExpectations = entry['expectations'];
    if (rawExpectations is! List || rawExpectations.isEmpty) {
      throw MappingsFormatException(
        source,
        'rule "$condition" needs at least one expectation',
      );
    }

    return Rule(
      condition: condition,
      expectations: [
        for (final e in rawExpectations) _readExpectation(source, e),
      ],
    );
  }

  static Expectation _readExpectation(String source, Object? raw) {
    if (raw is! Map) {
      throw MappingsFormatException(source, 'each expectation must be a map');
    }
    final entry = raw.cast<String, Object?>();
    _rejectUnknownKeys(
      source,
      entry.keys,
      _expectationKeys,
      'expectation key',
    );

    final element = entry['element'];
    if (element is! String) {
      throw MappingsFormatException(
        source,
        'an expectation needs an "element"',
      );
    }
    final property = entry['property'];
    if (property is! String) {
      throw MappingsFormatException(
        source,
        'expectation on "$element" needs a "property"',
      );
    }
    if (!entry.containsKey('equals')) {
      throw MappingsFormatException(
        source,
        'expectation on "$element" needs an "equals"',
      );
    }

    return Expectation(
      element: element,
      property: property,
      equals: entry['equals'],
    );
  }
}
