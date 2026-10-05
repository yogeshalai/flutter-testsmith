/// In-application instrumentation for Flutter Testsmith.
///
/// Add this to the application under test and call [TestSdk.initialize] as
/// early as possible. In production builds the instrumentation compiles out
/// entirely; see the gating discussion in ARCHITECTURE 9.2.
library;

// The protocol is re-exported, not merely depended on.
//
// flutter_testsmith's own public API is written in protocol types: `initialize`
// takes an `AppContext`, the tree inspector returns a `UiSnapshot`, the
// channel carries a `TestEvent`. An application outside this monorepo adds
// `flutter_testsmith` and nothing else, so any of those types it cannot name would
// force it to declare an internal platform package of its own — which is
// exactly the packaging failure this re-export removes.
//
// This also makes flutter_testsmith the single app-side surface: there is one
// import for an application to write, and one package for it to version.
export 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

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
