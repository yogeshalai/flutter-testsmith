// The import-graph rules of ADR-0011, against synthetic repositories laid
// out with the real component layout, and against this repository.
//
// Each synthetic tree is built in a temporary directory with its own
// .dart_tool/package_config.json, so nothing here runs pub. External
// packages live in a second temporary directory, standing in for the pub
// cache, so "outside the repository" is exercised for real.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../scripts/import_graph.dart';

/// The legacy package directories, by package name.
const _legacy = {
  'flutter_testsmith': 'packages/flutter_testsmith',
  'flutter_testsmith_protocol': 'packages/flutter_testsmith_protocol',
  'flutter_testsmith_engine': 'packages/flutter_testsmith_engine',
  'flutter_testsmith_cli': 'packages/flutter_testsmith_cli',
  'flutter_testsmith_figma': 'integrations/flutter_testsmith_figma',
  'ai_client': 'integrations/ai_client',
};

class _Tree {
  _Tree()
      : root = Directory.systemTemp.createTempSync('import_graph_repo'),
        cache = Directory.systemTemp.createTempSync('import_graph_cache');

  final Directory root;
  final Directory cache;
  final Map<String, String> _external = {};

  void write(String relative, String content) =>
      File('${root.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  /// An external package in the stand-in pub cache.
  void external(String name, {Map<String, Object> dependencies = const {}}) {
    final dir = Directory('${cache.path}/$name')..createSync(recursive: true);
    File('${dir.path}/pubspec.yaml').writeAsStringSync(
      'name: $name\ndependencies:\n'
      '${dependencies.entries.map((e) => '  ${e.key}: ${jsonEncode(e.value)}').join('\n')}\n',
    );
    File('${dir.path}/lib/$name.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('// $name\n');
    _external[name] = dir.uri.toString();
  }

  ImportGraph graph() {
    final packages = [
      for (final MapEntry(key: name, value: dir) in _legacy.entries)
        {'name': name, 'rootUri': '../$dir', 'packageUri': 'lib/'},
      for (final MapEntry(key: name, value: uri) in _external.entries)
        {'name': name, 'rootUri': uri, 'packageUri': 'lib/'},
    ];
    File('${root.path}/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': packages}));
    return ImportGraph.load(root.path);
  }

  void delete() {
    root.deleteSync(recursive: true);
    cache.deleteSync(recursive: true);
  }
}

/// The smallest legal SDK entry point: it reaches the protocol, as the
/// real one does.
void _cleanSdk(_Tree tree) {
  tree
    ..write(sdkEntry, "export 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';\nexport 'src/gating.dart';\n")
    ..write('packages/flutter_testsmith/lib/src/gating.dart', "import 'package:flutter/foundation.dart';\n")
    ..write('packages/flutter_testsmith_protocol/lib/flutter_testsmith_protocol.dart', "export 'src/envelope.dart';\n")
    ..write('packages/flutter_testsmith_protocol/lib/src/envelope.dart', '// envelope\n')
    ..external('flutter', dependencies: {'sky_engine': {'sdk': 'flutter'}});
}

void main() {
  late _Tree tree;
  setUp(() => tree = _Tree());
  tearDown(() => tree.delete());

  group('classify', () {
    test('maps legacy and destination locations to the same component', () {
      expect(classify('packages/flutter_testsmith_engine/lib/src/a.dart'), Component.engine);
      expect(classify('packages/flutter_testsmith/lib/src/engine/a.dart'), Component.engine);
      expect(classify('packages/flutter_testsmith/lib/engine.dart'), Component.engine);
      expect(classify('packages/flutter_testsmith_cli/bin/testsmith.dart'), Component.cli);
      expect(classify('packages/flutter_testsmith/bin/testsmith.dart'), Component.cli);
      expect(classify('integrations/ai_client/lib/ai_client.dart'), Component.ai);
      expect(classify('packages/flutter_testsmith/lib/src/ai/x.dart'), Component.ai);
    });

    test('gives the rest of the published lib/ to the SDK, and nothing else to anyone', () {
      expect(classify('packages/flutter_testsmith/lib/src/gating.dart'), Component.sdk);
      expect(classify(sdkEntry), Component.sdk);
      expect(classify(r'packages\flutter_testsmith\lib\src\gating.dart'), Component.sdk);
      expect(classify('examples/ecommerce_app/lib/main.dart'), isNull);
      expect(classify('packages/flutter_testsmith/test/x_test.dart'), isNull);
      // A sibling whose name merely starts the same is not inside it.
      expect(classify('packages/flutter_testsmith_engine_extra/lib/a.dart'), isNull);
    });
  });

  group('placements', () {
    test('reports legacy, destination, split and absent from the files present', () {
      tree
        ..write('packages/flutter_testsmith/lib/flutter_testsmith.dart', '')
        ..write('packages/flutter_testsmith_protocol/lib/p.dart', '')
        ..write('packages/flutter_testsmith/lib/src/engine/e.dart', '')
        ..write('integrations/ai_client/lib/a.dart', '')
        ..write('packages/flutter_testsmith/lib/src/ai/a.dart', '');
      final found = placements(tree.root.path);
      expect(found[Component.sdk], Placement.destination);
      expect(found[Component.protocol], Placement.legacy);
      expect(found[Component.engine], Placement.destination);
      expect(found[Component.ai], Placement.split);
      expect(found[Component.figma], Placement.absent);
    });
  });

  group('rule A - SDK isolation', () {
    test('allows the SDK to reach the protocol', () {
      _cleanSdk(tree);
      expect(sdkIsolationViolations(tree.graph()), isEmpty);
    });

    test('finds the engine behind an intermediate SDK file, with the chain', () {
      _cleanSdk(tree);
      tree
        ..write('packages/flutter_testsmith/lib/src/gating.dart',
            "import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';\n")
        ..write('packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart', '// engine\n');
      final violations = sdkIsolationViolations(tree.graph());
      expect(violations, hasLength(1));
      expect(violations.single.message, contains('engine'));
      expect(violations.single.message, contains('lib/src/gating.dart -> packages/flutter_testsmith_engine'));
    });

    test('follows exports and every branch of a conditional import', () {
      _cleanSdk(tree);
      tree
        ..write('packages/flutter_testsmith/lib/src/gating.dart',
            "import 'none.dart' if (dart.library.io) 'package:ai_client/ai_client.dart';\n")
        ..write('packages/flutter_testsmith/lib/src/none.dart', '')
        ..write(sdkEntry, "export 'src/gating.dart';\nexport \"package:flutter_testsmith_figma/flutter_testsmith_figma.dart\";\n")
        ..write('integrations/ai_client/lib/ai_client.dart', '')
        ..write('integrations/flutter_testsmith_figma/lib/flutter_testsmith_figma.dart', '');
      final messages = sdkIsolationViolations(tree.graph()).map((v) => v.message).join('\n');
      expect(messages, contains('ai file'));
      expect(messages, contains('figma file'));
    });

    test('holds after the move: a relative import into lib/src/engine is caught', () {
      _cleanSdk(tree);
      tree
        ..write('packages/flutter_testsmith/lib/src/gating.dart', "import 'engine/runner.dart';\n")
        ..write('packages/flutter_testsmith/lib/src/engine/runner.dart', '');
      final violations = sdkIsolationViolations(tree.graph());
      expect(violations.single.message, contains('engine'));
    });

    test('reports an import it cannot resolve instead of passing', () {
      _cleanSdk(tree);
      tree.write('packages/flutter_testsmith/lib/src/gating.dart', "import 'missing.dart';\n");
      expect(sdkIsolationViolations(tree.graph()).single.message, contains('missing.dart'));
    });
  });

  group('rule B - Flutter-free components', () {
    test('passes components that reach no Flutter', () {
      _cleanSdk(tree);
      tree.write('packages/flutter_testsmith_engine/lib/e.dart', "import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';\n");
      expect(flutterFreeViolations(tree.graph()), isEmpty);
    });

    test('catches package:flutter, however the URI is quoted', () {
      _cleanSdk(tree);
      tree.write('packages/flutter_testsmith_engine/lib/e.dart', 'import "package:flutter/foundation.dart";\n');
      expect(flutterFreeViolations(tree.graph()).single.message, contains('engine reaches package:flutter'));
    });

    test('catches dart:ui behind a conditional import', () {
      _cleanSdk(tree);
      tree
        ..write('integrations/flutter_testsmith_figma/lib/f.dart', "import 'stub.dart' if (dart.library.ui) 'dart:ui';\n")
        ..write('integrations/flutter_testsmith_figma/lib/stub.dart', '');
      expect(flutterFreeViolations(tree.graph()).single.message, contains('figma reaches dart:ui'));
    });

    test('catches an external package that depends on the Flutter SDK transitively', () {
      _cleanSdk(tree);
      tree
        ..external('widget_kit', dependencies: {'flutter': {'sdk': 'flutter'}})
        ..external('harmless_looking', dependencies: {'widget_kit': '^1.0.0'})
        ..write('integrations/ai_client/lib/a.dart', "import 'package:harmless_looking/harmless_looking.dart';\n");
      expect(flutterFreeViolations(tree.graph()).single.message,
          contains('ai reaches package:harmless_looking'));
    });

    test('catches a component reaching the SDK component, before and after the move', () {
      _cleanSdk(tree);
      tree
        ..write('packages/flutter_testsmith_cli/lib/src/c.dart', "import 'package:flutter_testsmith/flutter_testsmith.dart';\n")
        ..write('packages/flutter_testsmith/lib/src/engine/e.dart', "import '../gating.dart';\n");
      final messages = flutterFreeViolations(tree.graph()).map((v) => v.message).join('\n');
      expect(messages, contains('cli reaches'));
      expect(messages, contains('engine reaches'));
      expect(messages, contains('Flutter SDK component'));
    });
  });

  group('rule C - the published package depends on pub.dev and Flutter only', () {
    PublishPolicy policy(String dependencies, {Map<Component, Placement>? placed}) => publishPolicy(
          loadYaml('name: flutter_testsmith\ndependencies:\n$dependencies') as YamlMap,
          workspaceMembers: {'flutter_testsmith_protocol'},
          componentPlacements: placed,
        );

    test('accepts hosted constraints, pub.dev hosts and the Flutter SDK', () {
      final result = policy('''
  meta: ^1.15.0
  yaml:
    version: ^3.1.2
  args:
    hosted: https://pub.dev
    version: ^2.6.0
  image:
    hosted:
      name: image
      url: https://pub.dev/
    version: ^4.0.0
  flutter:
    sdk: flutter
''');
      expect(result.violations, isEmpty);
      expect(result.pending, isEmpty);
    });

    test('rejects path, git, another host and another SDK', () {
      final result = policy('''
  a:
    path: ../a
  b:
    git: https://example.invalid/b.git
  c:
    hosted: https://packages.example.invalid
    version: ^1.0.0
  d:
    sdk: fuchsia
''');
      expect(result.violations.map((v) => v.message).join('\n'),
          allOf(contains('a through a "path"'), contains('b through a "git"'),
              contains('packages.example.invalid'), contains('"fuchsia" SDK')));
    });

    test('lists a workspace member as pending, not as a violation', () {
      final result = policy('  flutter_testsmith_protocol: ^0.1.1\n');
      expect(result.violations, isEmpty);
      expect(result.pending.single, contains('workspace member flutter_testsmith_protocol'));
    });

    test('lists unmoved components and publish_to as pending when asked', () {
      final result = publishPolicy(
        loadYaml('name: flutter_testsmith\npublish_to: none\n') as YamlMap,
        workspaceMembers: const {},
        componentPlacements: {
          Component.sdk: Placement.destination,
          Component.engine: Placement.legacy,
          Component.ai: Placement.split,
          Component.figma: Placement.destination,
        },
      );
      expect(result.pending, hasLength(3));
      expect(result.pending.join('\n'),
          allOf(contains('engine is still outside'), contains('ai is split'), contains('publish_to: none')));
    });
  });

  group('this repository', () {
    final repo = Directory.current.path;

    test('rules A and B hold, and actually cover the code', () {
      final graph = ImportGraph.load(repo);
      expect(sdkIsolationViolations(graph), isEmpty);
      expect(flutterFreeViolations(graph), isEmpty);

      final reached = graph.closure([sdkEntry]).files.keys.map(classify).toSet();
      expect(reached, containsAll([Component.sdk, Component.protocol]),
          reason: 'the SDK re-exports the protocol; a walk that misses it proves nothing');
      for (final component in flutterFreeComponents) {
        expect(componentFiles(repo, component), isNotEmpty, reason: '${component.name} has no files to check');
      }
    });

    test('rule C has no violations, and everything pending is migration work', () {
      final placed = placements(repo);
      final result = publishPolicy(
        loadYaml(File('$repo/$publishedPackageDir/pubspec.yaml').readAsStringSync()) as YamlMap,
        workspaceMembers: workspaceMemberNames(repo, except: 'flutter_testsmith'),
        componentPlacements: placed,
      );
      expect(result.violations, isEmpty);
      for (final item in result.pending) {
        expect(item, anyOf(contains('workspace member'), contains('outside'), contains('split'), contains('publish_to')));
      }
      expect(placed.values, isNot(contains(Placement.absent)));
    });
  });
}
