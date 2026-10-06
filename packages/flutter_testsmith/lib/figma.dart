/// Fetches Figma designs and normalises them for comparison.
///
/// Optional: the platform builds, tests and runs with no Figma access
/// configured, and validation reports a skip rather than a failure when
/// no design is available.
library;

export 'src/figma/figma_spec.dart';
export 'src/figma/layout_semantics.dart';
export 'src/figma/node_mapping.dart';
export 'src/figma/normaliser.dart';
export 'src/figma/figma_client.dart';
