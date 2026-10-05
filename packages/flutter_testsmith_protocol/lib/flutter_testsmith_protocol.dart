/// The versioned contract shared verbatim by the in-app test SDK and the
/// out-of-process test engine.
///
/// This package has no dependency beyond `meta`, because it is linked into
/// production applications through `flutter_testsmith`: anything it depends on becomes
/// a dependency of every application under test.
library;

export 'src/animation.dart';
export 'src/app_context.dart';
export 'src/envelope.dart';
export 'src/errors.dart';
export 'src/event_type.dart';
export 'src/geometry.dart';
export 'src/handshake.dart';
export 'src/json.dart' show formatUtcTimestamp;
export 'src/payloads.dart';
export 'src/ui_tree.dart';
export 'src/version.dart';
