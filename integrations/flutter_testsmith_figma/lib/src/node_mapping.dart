import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// Binds Figma node ids to the platform's semantic element ids.
///
/// This layer is not optional, and the reason is visible the moment you
/// look at a real file: the `Product Details` frame this was built
/// against contains layers called `Frame 42980`, `Rectangle 91` and
/// `Component 3`. Treating a layer name as a semantic id would be worse
/// than having no id at all, because it would look like it worked.
///
/// Mapping is by **node id**, which survives a rename. The layer name is
/// carried alongside purely as a hint for whoever maintains the file.
@immutable
class FigmaNodeMapping {
  const FigmaNodeMapping(this._byNodeId, {this.screen});

  final Map<String, String> _byNodeId;

  /// The application screen this mapping is for.
  final String? screen;

  Map<String, String> get entries => Map.unmodifiable(_byNodeId);

  String? semanticIdFor(String nodeId) => _byNodeId[nodeId];

  bool get isEmpty => _byNodeId.isEmpty;

  factory FigmaNodeMapping.parse(String yamlText, {required String source}) {
    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      throw FormatException('$source: invalid YAML: ${error.message}');
    }
    if (loaded is! Map) {
      throw FormatException('$source: expected a mapping at the root');
    }

    final root = loaded.cast<String, Object?>();
    for (final key in root.keys) {
      if (key != 'screen' && key != 'nodes') {
        throw FormatException(
          '$source: unknown key "$key". Known: screen, nodes.',
        );
      }
    }

    final rawNodes = root['nodes'];
    if (rawNodes != null && rawNodes is! Map) {
      throw FormatException('$source: "nodes" must be a map of id to id');
    }

    final byNodeId = <String, String>{};
    final seenSemanticIds = <String, String>{};

    for (final entry
        in ((rawNodes as Map?) ?? const {}).cast<Object?, Object?>().entries) {
      final nodeId = entry.key.toString();
      final semanticId = entry.value.toString();

      final existing = seenSemanticIds[semanticId];
      if (existing != null) {
        // Two design nodes claiming one element makes every comparison
        // about that element ambiguous.
        throw FormatException(
          '$source: "$semanticId" is mapped from both "$existing" and '
          '"$nodeId". Each semantic id must come from one node.',
        );
      }
      seenSemanticIds[semanticId] = nodeId;
      byNodeId[nodeId] = semanticId;
    }

    // The same check every other field in this file has. `screen` was a
    // cast, so the same kind of slip in the same file gave two answers:
    // a mistyped `nodes` named the file and said what was legal, while a
    // mistyped `screen` left a `TypeError` - not a `FormatException`,
    // and not an `Exception` at all - which walked past `figma pull` and
    // `resolveFigmaSources`, both of which catch the format exception
    // this parser raises five other times, and ended the process at 255.
    //
    // Absent and an explicit `null` both still mean "no screen", exactly
    // as the cast did: the template does not force the line, and a
    // mapping without one has always been valid.
    final screen = root['screen'];
    if (screen != null && screen is! String) {
      throw FormatException(
        '$source: "screen" must be the application route this design '
        'describes, as in `screen: /product/details`',
      );
    }

    return FigmaNodeMapping(byNodeId, screen: screen as String?);
  }

  /// Renders a starter mapping file listing what the frame contains.
  ///
  /// Handing someone an empty file and a 100KB design is not a workable
  /// starting point; this gives them every candidate with its name and
  /// text as a comment, to fill in or delete.
  static String template(
    String screen,
    Iterable<({String nodeId, String name, String? text})> candidates,
  ) {
    final buffer = StringBuffer()
      ..writeln('# Figma node id -> semantic element id.')
      ..writeln('#')
      ..writeln('# Mapped by node id, which survives a layer rename. Layer')
      ..writeln('# names in real files are things like "Frame 42980", so')
      ..writeln('# they are shown only as a hint.')
      ..writeln('#')
      ..writeln('# Delete the lines you do not need.')
      ..writeln()
      ..writeln('screen: $screen')
      ..writeln()
      ..writeln('nodes:');

    for (final candidate in candidates) {
      final hint = candidate.text == null
          ? candidate.name
          : '${candidate.name} - "${candidate.text}"';
      buffer.writeln('  # $hint');
      buffer.writeln('  # "${candidate.nodeId}": some.element.id');
    }

    return buffer.toString();
  }
}
