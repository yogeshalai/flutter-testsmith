import 'dart:io';

import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// A malformed suite.
@immutable
class SuiteFormatException implements Exception {
  const SuiteFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'SuiteFormatException in $source: $message';
}

/// What to do when a test does not pass.
enum OnFailure {
  /// Run the rest anyway. The default, because a suite exists to tell
  /// you everything that is wrong, and stopping at the first failure
  /// hides the others behind it.
  carryOn('continue'),

  /// Stop. Useful when the first failure makes the rest meaningless -
  /// or expensive.
  stop('stop');

  const OnFailure(this.wire);

  final String wire;

  static OnFailure? fromWire(Object? wire) {
    for (final value in values) {
      if (value.wire == wire) return value;
    }
    return null;
  }
}

/// What to do to the installed application before a test runs.
enum StateReset {
  /// Nothing. The default: a suite that wiped the device between every
  /// test would spend its life re-signing-in, and would make each test's
  /// preconditions invisible.
  none('none'),

  /// Clear the application's stored state, as a fresh install would be.
  ///
  /// Declared per test, never implied. The Login flow needs a signed-out
  /// device and the dashboard flows need a signed-in one, so the suite
  /// has to be able to say which - and saying it here keeps it out of
  /// the flow DSL, where it would become a step every flow could use to
  /// reach into the device.
  clearState('clearState');

  const StateReset(this.wire);

  final String wire;

  static StateReset? fromWire(Object? wire) {
    for (final value in values) {
      if (value.wire == wire) return value;
    }
    return null;
  }
}

/// How the application under test is built and launched.
@immutable
class SuiteApp {
  const SuiteApp({
    this.path = '.',
    this.target,
    this.flavor,
    this.dartDefines = const [],
  });

  /// Where the application is, relative to the suite file.
  ///
  /// Everything else - flows, mappings, designs, profiles, baselines -
  /// is then relative to that root.
  final String path;

  final String? target;
  final String? flavor;
  final List<String> dartDefines;

  static const Set<String> _keys = {
    'path',
    'target',
    'flavor',
    'dartDefines',
  };
}

/// A condition the suite needs, and what the application looks like when
/// it is not met.
///
/// Declared by a person, in the suite, because only a person knows that
/// *this* application shows `/login` when it holds no session. The runner
/// never infers it and never reads the application's storage to find out:
/// the first would be a guess, and the second is the bypass this platform
/// refuses.
///
/// What it buys is the difference between "four screens are wrong" and
/// "the device was never ready to be asked".
@immutable
class SuitePrecondition {
  const SuitePrecondition({
    required this.name,
    required this.unmetOn,
    this.description = '',
    this.remedy = '',
  });

  final String name;
  final String description;

  /// Routes the application shows when this condition is **not** met.
  ///
  /// Checked against the last route a test actually reached. Required,
  /// and required to be non-empty: a precondition with nothing to check
  /// against could never be unmet, so declaring one would quietly buy
  /// nothing while looking like it bought something.
  final List<String> unmetOn;

  /// What a person should do about it. Carried into the result, so the
  /// report says how to fix the run rather than only that it broke.
  final String remedy;

  static const Set<String> _keys = {'description', 'unmetOn', 'remedy'};
}

/// One test in a suite: a flow, and what to arrange before it.
@immutable
class SuiteTest {
  const SuiteTest({
    required this.id,
    required this.flow,
    this.reset = StateReset.none,
    this.grant = const [],
    this.optional = false,
    this.requires = const [],
  });

  /// The stable identity of this test.
  ///
  /// Names a row in the report and a directory on disk, so it has to be
  /// unique and has to be chosen rather than derived from a path - a
  /// path changes when a file moves, and a result that changes identity
  /// when a file moves cannot be compared with yesterday's.
  final String id;

  /// The flow file, relative to the application root.
  final String flow;

  final StateReset reset;

  /// Permissions to grant after a reset.
  ///
  /// Clearing an application's state also revokes what the user granted
  /// it, and on Android the resulting permission dialog is drawn over
  /// the application - which is a tap landing on a system dialog rather
  /// than on the button the flow asked for.
  final List<String> grant;

  /// Whether the suite can pass without this test passing.
  final bool optional;

  /// The preconditions this test needs, by name.
  ///
  /// Empty by default, so a suite written before E-04 is unaffected. When
  /// one is named and the application ends somewhere the precondition
  /// calls unmet, the result is an environment finding rather than a
  /// verdict on a screen nobody was ever in a position to judge.
  final List<String> requires;

  bool get required => !optional;

  static const Set<String> _keys = {
    'id',
    'flow',
    'reset',
    'grant',
    'optional',
    'requires',
  };
}

/// An ordered list of flows, and the device they run against.
///
/// There is deliberately no discovery. A suite is a list somebody wrote,
/// in the order they wrote it: a suite that finds its own contents
/// silently changes what it tests when a file appears, and the first
/// anyone knows of it is a result that moved for no reason in the diff.
@immutable
class SuiteFile {
  const SuiteFile({
    required this.name,
    required this.deviceProfile,
    required this.tests,
    this.app = const SuiteApp(),
    this.mockApiPort,
    this.onFailure = OnFailure.carryOn,
    this.devicePermissions = const [],
    this.preconditions = const {},
  });

  final String name;

  /// The id of the device profile this suite runs against.
  ///
  /// A profile id, never a serial: a serial names the handset on one
  /// desk, and a suite that named one could only ever run there.
  final String deviceProfile;

  final SuiteApp app;
  final int? mockApiPort;
  final OnFailure onFailure;

  /// Permissions granted once, at suite setup, to the application under
  /// test.
  ///
  /// Declared rather than inferred, and granted rather than dismissed. A
  /// runtime permission dialog drawn over the application swallows the
  /// tap meant for the button beneath it, and the run then reports a tap
  /// that happened and a navigation that did not - which cost E-02 half a
  /// day and cost E-03 two ERRORs. Granting at setup is also what stops
  /// the next run inheriting a half-permissioned device: a test declaring
  /// `clearState` revokes these along with everything else.
  final List<String> devicePermissions;

  /// Named conditions a test may require, by name.
  final Map<String, SuitePrecondition> preconditions;

  /// In declared order. That order is part of the test.
  final List<SuiteTest> tests;

  /// The ids of the tests requiring [precondition], in declared order.
  List<String> testsRequiring(String precondition) => [
        for (final test in tests)
          if (test.requires.contains(precondition)) test.id,
      ];

  static const Set<String> _keys = {
    'suite',
    'app',
    'device',
    'mockApi',
    'onFailure',
    'preconditions',
    'tests',
  };

  factory SuiteFile.parse(String yamlText, {required String source}) {
    Never bad(String message) => throw SuiteFormatException(source, message);

    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      bad('invalid YAML: ${error.message}');
    }
    if (loaded is! Map) {
      bad('expected a mapping at the root with suite, device and tests');
    }

    Map<String, Object?> asMap(Object? node, String what) {
      if (node is! Map) bad('"$what" must be a mapping');
      return node.cast<Object?, Object?>().map(
            (key, value) => MapEntry(key.toString(), value),
          );
    }

    final root = asMap(loaded, 'root');

    void checkKeys(Map<String, Object?> map, Set<String> known, String what) {
      for (final key in map.keys) {
        if (known.contains(key)) continue;
        bad('unknown $what key "$key". Known: ${known.join(', ')}.');
      }
    }

    checkKeys(root, _keys, 'top-level');

    final name = root['suite'];
    if (name is! String || name.isEmpty) {
      bad('a suite needs a "suite" name');
    }

    final device = asMap(root['device'] ?? const {}, 'device');
    checkKeys(device, const {'profile', 'permissions'}, 'device');
    final profile = device['profile'];
    if (profile is! String || profile.isEmpty) {
      bad(
        'a suite needs "device: profile:" - the id of a device profile, '
        'not a device serial',
      );
    }

    final rawPermissions = device['permissions'];
    if (rawPermissions != null && rawPermissions is! List) {
      bad('"device.permissions" must be a list of permission names');
    }
    final devicePermissions = [
      for (final permission in (rawPermissions as List?) ?? const [])
        permission.toString(),
    ];

    final appNode = root['app'];
    final app = appNode == null
        ? const SuiteApp()
        : () {
            final map = asMap(appNode, 'app');
            checkKeys(map, SuiteApp._keys, 'app');
            final defines = map['dartDefines'];
            if (defines != null && defines is! List) {
              bad('"app.dartDefines" must be a list');
            }
            return SuiteApp(
              path: map['path']?.toString() ?? '.',
              target: map['target']?.toString(),
              flavor: map['flavor']?.toString(),
              dartDefines: [
                for (final d in (defines as List?) ?? const []) d.toString(),
              ],
            );
          }();

    final mockNode = root['mockApi'];
    int? port;
    if (mockNode != null) {
      final map = asMap(mockNode, 'mockApi');
      checkKeys(map, const {'port'}, 'mockApi');
      final raw = map['port'];
      if (raw is! int || raw <= 0) bad('"mockApi.port" must be a port number');
      port = raw;
    }

    final rawPolicy = root['onFailure'];
    final onFailure =
        rawPolicy == null ? OnFailure.carryOn : OnFailure.fromWire(rawPolicy);
    if (onFailure == null) {
      bad(
        'unknown onFailure "$rawPolicy". Known: '
        '${OnFailure.values.map((v) => v.wire).join(', ')}.',
      );
    }

    // Parsed before the tests, because a test's "requires" is validated
    // against it. A name that matches nothing is a typo, and a typo that
    // silently disables a precondition is a suite that goes on reporting
    // environment problems as product failures.
    final preconditions = <String, SuitePrecondition>{};
    final rawPreconditions = root['preconditions'];
    if (rawPreconditions != null) {
      final map = asMap(rawPreconditions, 'preconditions');
      for (final entry in map.entries) {
        final body = asMap(entry.value ?? const {}, 'precondition');
        checkKeys(body, SuitePrecondition._keys, 'precondition');

        final unmetOn = body['unmetOn'];
        if (unmetOn is! List || unmetOn.isEmpty) {
          bad(
            'precondition "${entry.key}" needs a non-empty "unmetOn": the '
            'routes the application shows when it is not met. Without one '
            'the condition could never be found unmet, and an unmet '
            'precondition would go on being reported as a product failure.',
          );
        }

        preconditions[entry.key] = SuitePrecondition(
          name: entry.key,
          description: body['description']?.toString() ?? '',
          unmetOn: [for (final route in unmetOn) route.toString()],
          remedy: body['remedy']?.toString() ?? '',
        );
      }
    }

    final rawTests = root['tests'];
    if (rawTests is! List || rawTests.isEmpty) {
      bad('a suite needs at least one test under "tests"');
    }

    final tests = <SuiteTest>[];
    final seen = <String>{};
    for (final entry in rawTests) {
      final map = asMap(entry, 'test');
      checkKeys(map, SuiteTest._keys, 'test');

      final id = map['id'];
      if (id is! String || id.isEmpty) {
        bad('every test needs an "id"; it names its results and its output '
            'directory');
      }
      if (!seen.add(id)) {
        bad('two tests share the id "$id". Ids name results and directories, '
            'so they must be unique.');
      }

      final flow = map['flow'];
      if (flow is! String || flow.isEmpty) {
        bad('test "$id" needs a "flow" - the path to its flow file');
      }

      final rawReset = map['reset'];
      final reset =
          rawReset == null ? StateReset.none : StateReset.fromWire(rawReset);
      if (reset == null) {
        bad(
          'test "$id" has an unknown reset "$rawReset". Known: '
          '${StateReset.values.map((v) => v.wire).join(', ')}.',
        );
      }

      final rawGrant = map['grant'];
      if (rawGrant != null && rawGrant is! List) {
        bad('test "$id": "grant" must be a list of permissions');
      }

      final optional = map['optional'] ?? false;
      if (optional is! bool) {
        bad('test "$id": "optional" must be true or false');
      }

      final rawRequires = map['requires'];
      if (rawRequires != null && rawRequires is! List) {
        bad('test "$id": "requires" must be a list of precondition names');
      }
      final requires = [
        for (final r in (rawRequires as List?) ?? const []) r.toString(),
      ];
      for (final precondition in requires) {
        if (preconditions.containsKey(precondition)) continue;
        bad(
          'test "$id" requires "$precondition", but the suite declares no '
          'precondition by that name. Known: '
          '${preconditions.isEmpty ? '(none)' : preconditions.keys.join(', ')}.',
        );
      }

      tests.add(SuiteTest(
        id: id,
        flow: flow,
        reset: reset,
        grant: [
          for (final g in (rawGrant as List?) ?? const []) g.toString(),
        ],
        optional: optional,
        requires: requires,
      ));
    }

    return SuiteFile(
      name: name,
      deviceProfile: profile,
      app: app,
      mockApiPort: port,
      onFailure: onFailure,
      devicePermissions: devicePermissions,
      preconditions: preconditions,
      tests: tests,
    );
  }

  /// Flows this suite names that are not on disk.
  ///
  /// [project] is the application root, not the suite file's directory:
  /// a flow is written the way a person refers to it from the project -
  /// `mytest/tests/home.yaml` - rather than relative to wherever the
  /// suite file happens to live.
  ///
  /// Checked before anything is launched: there is no point building an
  /// application to discover a path typo.
  List<String> missingFlows(Directory project) => [
        for (final test in tests)
          if (!File('${project.path}/${test.flow}').existsSync())
            'test "${test.id}" names ${test.flow}, which is not there',
      ];
}
