/// Fetches Figma designs and normalises them for comparison.
///
/// Optional: the platform builds, tests and runs with no Figma access
/// configured, and validation reports a skip rather than a failure when
/// no design is available.
library;

export 'src/figma_spec.dart';
export 'src/layout_semantics.dart';
export 'src/node_mapping.dart';
export 'src/normaliser.dart';
export 'src/figma_client.dart';
