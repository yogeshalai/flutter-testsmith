import 'package:flutter_testsmith/protocol.dart';

/// Handles one inbound RPC.
///
/// Parameters arrive as strings because that is what the VM Service protocol
/// delivers for service extension arguments.
typedef RpcHandler = Future<Map<String, Object?>> Function(
  Map<String, String> params,
);

/// The application's side of the engine connection.
///
/// Kept as an interface so the SDK is not bound to the VM Service. A
/// WebSocket implementation is planned for release-mode and device-farm
/// execution; see ADR-0002.
abstract interface class SdkChannel {
  /// Sends an event to an attached engine. Fire-and-forget: an event emitted
  /// with nothing attached is simply not delivered, which is why the session
  /// also buffers it.
  void emit(TestEvent event);

  /// Registers a handler for [method], which must be namespaced
  /// `ext.mytest.*`.
  void handle(String method, RpcHandler handler);

  Future<void> close();
}
