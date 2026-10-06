// The rule that keeps finding E-01 from coming back.
//
// `flutter_testsmith` and `flutter_testsmith_protocol` are consumed by applications outside this
// repository. Such an application fetches them from a package repository,
// which means every dependency they declare must be resolvable from a
// package repository too. A `path:` dependency points at a directory only
// this monorepo has; a `git:` dependency pins a URL the consumer has no
// reason to trust. Either one turns "add flutter_testsmith to your app" into
// "clone the platform first", which is the problem this milestone exists
// to remove.
//
// Kept as a pure function, separate from the script that runs it, so the
// rule is unit-testable against synthetic pubspecs as well as the real
// ones.
import 'package:yaml/yaml.dart';

/// The packages an application outside this monorepo resolves: the one it
/// names, `flutter_testsmith`, and every workspace member that package
/// depends on.
///
/// Since the engine moved inside flutter_testsmith (ADR-0011), its two
/// integrations are dependencies of flutter_testsmith too. Each leaves
/// this list when it moves inside as well.
const List<String> externallyConsumablePackages = [
  'flutter_testsmith_protocol',
  'flutter_testsmith',
  'flutter_testsmith_figma',
  'ai_client',
];

/// The repository-relative directory of [package], one of
/// [externallyConsumablePackages]. The integrations live under
/// `integrations/`, everything else under `packages/`.
String packageDirectory(String package) => switch (package) {
      'flutter_testsmith_figma' || 'ai_client' => 'integrations/$package',
      _ => 'packages/$package',
    };

/// Dependency sources that cannot be resolved by a consumer who fetched
/// the package from a repository.
const List<String> _unresolvableSources = ['path', 'git'];

/// Describes every dependency of [package] that an external consumer could
/// not resolve. Empty means the package is externally consumable.
///
/// Only `dependencies:` is examined. `dev_dependencies` are not resolved
/// for a consumer at all, so a path dependency there is harmless — and
/// useful, since it is how a package tests against its siblings.
List<String> externallyConsumableViolations(String package, YamlMap pubspec) {
  final dependencies = pubspec['dependencies'];
  if (dependencies is! YamlMap) return const [];

  final violations = <String>[];
  for (final entry in dependencies.entries) {
    final name = entry.key.toString();
    final spec = entry.value;
    if (spec is! YamlMap) continue; // A bare version constraint.

    for (final source in _unresolvableSources) {
      if (spec.containsKey(source)) {
        violations.add(
          '$package depends on $name through a "$source" source. An '
          'application outside this repository cannot resolve it; publish '
          '$name to the same repository as $package instead.',
        );
      }
    }
  }
  return violations;
}
