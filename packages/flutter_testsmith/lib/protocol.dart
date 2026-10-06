/// The versioned contract shared verbatim by the in-app test SDK and the
/// out-of-process test engine.
///
/// This component has no dependency beyond `meta`, because it is linked into
/// production applications through `flutter_testsmith`: anything it depends on becomes
/// a dependency of every application under test.
library;

export 'src/protocol/animation.dart';
export 'src/protocol/app_context.dart';
export 'src/protocol/envelope.dart';
export 'src/protocol/errors.dart';
export 'src/protocol/event_type.dart';
export 'src/protocol/geometry.dart';
export 'src/protocol/handshake.dart';
export 'src/protocol/json.dart' show formatUtcTimestamp;
export 'src/protocol/payloads.dart';
export 'src/protocol/ui_tree.dart';
export 'src/protocol/version.dart';
