import 'dart:developer' as developer;

import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'rpc_dispatcher.dart';
import 'sdk_channel.dart';

/// The stream name events are posted on.
const String kEventStreamKind = 'mytest';

/// Carries events and RPCs over the Dart VM Service.
///
/// This is intentionally the thinnest possible shell over `dart:developer`:
/// all routing, encoding and error handling lives in [RpcDispatcher], which
/// is unit tested. What remains here cannot be tested without a live VM
/// Service and is exercised by the on-device smoke test instead.
///
/// Note that `postEvent` is fire-and-forget - an event emitted with no
/// engine attached is simply dropped. Recovery of those events is the
/// session's ring buffer, not this class. See ARCHITECTURE 8.1.
class VmServiceChannel implements SdkChannel {
  VmServiceChannel({RpcDispatcher? dispatcher})
      : _dispatcher = dispatcher ?? RpcDispatcher();

  final RpcDispatcher _dispatcher;
  bool _closed = false;

  @override
  void emit(TestEvent event) {
    if (_closed) return;
    developer.postEvent(kEventStreamKind, event.toJson());
  }

  @override
  void handle(String method, RpcHandler handler) {
    _dispatcher.register(method, handler);
    developer.registerExtension(method, (String name, Map<String, String> params) async {
      final result = await _dispatcher.dispatch(name, params);
      return result.isError
          ? developer.ServiceExtensionResponse.error(
              developer.ServiceExtensionResponse.extensionError,
              result.body,
            )
          : developer.ServiceExtensionResponse.result(result.body);
    });
  }

  @override
  Future<void> close() async {
    // Service extensions cannot be unregistered from an isolate, so closing
    // stops emission rather than tearing anything down. The engine sees the
    // SESSION_END event that precedes this.
    _closed = true;
  }
}
