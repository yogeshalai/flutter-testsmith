/// In-application instrumentation for Flutter Testsmith.
///
/// Add this to the application under test and call [TestSdk.initialize] as
/// early as possible. In production builds the instrumentation compiles out
/// entirely; see the gating discussion in ARCHITECTURE 9.2.
library;

// The protocol is re-exported, not merely imported.
//
// flutter_testsmith's own public API is written in protocol types: `initialize`
// takes an `AppContext`, the tree inspector returns a `UiSnapshot`, the
// channel carries a `TestEvent`. An application adds `flutter_testsmith` and
// imports this one library, so every one of those types has to be nameable
// from here. The protocol was a separate package until ADR-0011 and now
// lives in lib/src/protocol; the re-export is what keeps it reachable from
// the single app-side import either way.
//
// This also makes flutter_testsmith the single app-side surface: there is one
// import for an application to write, and one package for it to version.
export 'protocol.dart';

export 'src/buffer/event_ring_buffer.dart';
export 'src/capture/http_overrides_capture.dart';
export 'src/capture/network_capture.dart';
export 'src/capture/surface_capture.dart';
export 'src/channel/rpc_dispatcher.dart';
export 'src/channel/sdk_channel.dart';
export 'src/identity/device_pixel_ratio.dart';
export 'src/inspection/animation_inspector.dart';
export 'src/inspection/retention_policy.dart';
export 'src/inspection/settle.dart';
export 'src/inspection/ui_tree_inspector.dart';
export 'src/identity/event_id.dart';
export 'src/identity/test_id.dart';
export 'src/navigation/test_navigator_observer.dart';
export 'src/channel/vm_service_channel.dart';
export 'src/runtime.dart';
export 'src/session/test_session.dart';
export 'src/test_sdk_facade.dart';
export 'src/config.dart';
export 'src/gating.dart';
export 'src/redaction.dart';
