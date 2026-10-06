import 'package:meta/meta.dart';

import '../dsl/steps.dart';
import '../dsl/test_flow.dart';

/// What the platform knows about one file.
@immutable
class IndexedFile {
  const IndexedFile({
    required this.path,
    this.screens = const {},
    this.elements = const {},
    this.isGlobal = false,
  });

  final String path;

  /// Screens this file is known to implement or describe.
  final Set<String> screens;

  /// Semantic ids this file is known to declare.
  final Set<String> elements;

  /// The file's blast radius is the whole application.
  ///
  /// Set for anything that wires the app together - the router, the
  /// entry point, the manifest, bundled assets - and for the test
  /// platform's own source. A change there can reach any screen, so
  /// narrowing on it would be a guess.
  final bool isGlobal;

  /// Whether anything at all is known about what this file affects.
  ///
  /// False means "no evidence", which is not the same as "no impact".
  /// An unattributable file selects the whole suite.
  bool get isAttributable =>
      isGlobal || screens.isNotEmpty || elements.isNotEmpty;

  @override
  String toString() => 'IndexedFile($path, screens: $screens, '
      'elements: $elements${isGlobal ? ', global' : ''})';
}

/// What one test flow touches.
@immutable
class FlowCoverage {
  const FlowCoverage({
    required this.path,
    required this.name,
    required this.screens,
    required this.elements,
  });

  final String path;
  final String name;

  /// Screens the flow asserts it reaches.
  final Set<String> screens;

  /// Semantic ids the flow taps or types into.
  final Set<String> elements;

  bool touchesScreen(String screen) => screens.contains(screen);

  bool touchesAnyOf(IndexedFile file) =>
      file.screens.any(screens.contains) ||
      file.elements.any(elements.contains);

  @override
  String toString() => 'FlowCoverage($name, screens: $screens)';
}

/// Everything known about which files relate to which flows.
@immutable
class ImpactIndex {
  const ImpactIndex({required this.flows, required this.files});

  final List<FlowCoverage> flows;
  final Map<String, IndexedFile> files;

  IndexedFile? file(String path) => files[_normalise(path)];

  static String _normalise(String path) => path.replaceAll('\\', '/');
}

/// Builds an [ImpactIndex] from file contents.
///
/// Takes contents rather than reading them, so the whole analysis is
/// testable without a filesystem and a CLI can decide what to read.
class ImpactIndexBuilder {
  ImpactIndexBuilder({required String appDirectory})
      : _appDirectory = _normalise(appDirectory);

  final String _appDirectory;
  final List<FlowCoverage> _flows = [];
  final Map<String, IndexedFile> _files = {};

  /// A screen's route, as Flutter code usually declares it.
  static final RegExp _route =
      RegExp(r'''route\s*=\s*['"](/[^'"]*)['"]''');

  static final RegExp _testKey =
      RegExp(r'''TestKey\(\s*['"]([^'"]+)['"]''');

  static final RegExp _testId =
      RegExp(r'''TestId\(\s*id:\s*['"]([^'"]+)['"]''');

  /// Markers that a file wires the application rather than being one
  /// screen of it.
  static final RegExp _appWiring =
      RegExp(r'\bvoid\s+main\s*\(|MaterialApp\(|CupertinoApp\(|'
          r'onGenerateRoute|GoRouter\(|Navigator\s*\.\s*onGenerateRoute');

  void addFlow(String path, TestFlow flow) {
    final screens = <String>{};
    final elements = <String>{};

    for (final step in flow.steps) {
      switch (step) {
        case ExpectScreenStep(:final screenId):
          screens.add(screenId);
        case TapStep(:final elementId):
          elements.add(elementId);
        case InputStep(:final elementId):
          elements.add(elementId);
        case ExpectElementStep(:final elementId):
          elements.add(elementId);
        default:
          break;
      }
    }

    _flows.add(
      FlowCoverage(
        path: _normalise(path),
        name: flow.name,
        screens: screens,
        elements: elements,
      ),
    );
  }

  /// Indexes a Dart source file by what it declares.
  /// Whether a matched id is a literal, or was built at runtime.
  ///
  /// `TestKey('products.item_$id')` matches the pattern perfectly and
  /// yields the string `products.item_$id`, which no flow can ever
  /// name. Keeping it is worse than finding nothing: the file then
  /// looks accounted for, and the analyser - whose whole rule is that a
  /// flow is excluded only on *positive evidence* - excludes every flow
  /// on evidence that is fake.
  ///
  /// Measured, not theorised. The shared `AsyncView` in the example
  /// application builds every id as `'$idPrefix.loading'` and friends;
  /// changing it selected **no flows at all**, when it can reach the
  /// loading, error and empty state of every screen in the app.
  static bool _isLiteral(String id) => !id.contains(r'$');

  void addSource(String path, String contents) {
    final screens = {
      for (final match in _route.allMatches(contents))
        if (_isLiteral(match.group(1)!)) match.group(1)!,
    };
    final elements = {
      for (final match in _testKey.allMatches(contents))
        if (_isLiteral(match.group(1)!)) match.group(1)!,
      for (final match in _testId.allMatches(contents))
        if (_isLiteral(match.group(1)!)) match.group(1)!,
    };

    _put(
      IndexedFile(
        path: _normalise(path),
        screens: screens,
        elements: elements,
        isGlobal: _appWiring.hasMatch(contents),
      ),
    );
  }

  /// Indexes a configuration file that names the screen it describes.
  void addConfig(String path, String screen) {
    _put(IndexedFile(path: _normalise(path), screens: {screen}));
  }

  /// Marks a file as affecting everything.
  void addGlobal(String path) {
    _put(IndexedFile(path: _normalise(path), isGlobal: true));
  }

  void _put(IndexedFile file) => _files[file.path] = file;

  ImpactIndex build() => ImpactIndex(
        flows: List.unmodifiable(_flows),
        files: Map.unmodifiable(_files),
      );

  String get appDirectory => _appDirectory;

  static String _normalise(String path) => path.replaceAll('\\', '/');
}
