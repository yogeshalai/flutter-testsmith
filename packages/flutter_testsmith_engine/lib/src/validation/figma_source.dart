import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';

/// Which design this screen is validated against, declared on the test.
///
/// Resolved at run time through the existing Figma client and its
/// on-disk cache, so two runs of the same test see the same design.
///
/// Declared in `mappings/<screen>.yaml`, which is user-owned test
/// configuration: hand-written, git-tracked, and never rewritten by the
/// engine.
@immutable
class FigmaSource {
  const FigmaSource({
    required this.url,
    required this.token,
    required this.mappingPath,
  });

  /// The Figma Dev URL, including `node-id=`.
  final String url;

  /// A reference to the access token, never the token.
  final SecretRef token;

  /// The node-id to semantic-id mapping, relative to the project.
  ///
  /// Mandatory, and deliberately so: real frames name their layers
  /// `Frame 42980` and `Rectangle 91`. Inferring semantic ids from layer
  /// names produces something that looks like it works and is wrong.
  final String mappingPath;

  @override
  String toString() => 'FigmaSource($url)';
}
