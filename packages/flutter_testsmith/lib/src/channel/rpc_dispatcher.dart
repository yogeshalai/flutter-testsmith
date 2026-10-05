import 'dart:convert';

import 'package:meta/meta.dart';

import 'sdk_channel.dart';

/// Every RPC this SDK serves lives under this prefix.
const String kRpcNamespace = 'ext.mytest.';

/// The outcome of an RPC, in a form that does not depend on
/// `dart:developer`.
///
/// Keeping the result type transport-neutral is what lets dispatch be unit
/// tested; the VM Service adapter is then a thin shell with no logic worth
/// testing.
@immutable
class RpcResult {
  const RpcResult.ok(this.body) : isError = false;
  const RpcResult.error(this.body) : isError = true;

  final String body;
  final bool isError;
}

/// Routes RPC calls to handlers and converts every outcome into a response.
///
/// No handler exception is allowed to escape: an uncaught error in a service
/// extension surfaces to the engine as a stalled call, which is far harder
/// to diagnose than a returned error.
class RpcDispatcher {
  final Map<String, RpcHandler> _handlers = <String, RpcHandler>{};

  Set<String> get methods => _handlers.keys.toSet();

  void register(String method, RpcHandler handler) {
    if (!method.startsWith(kRpcNamespace)) {
      throw ArgumentError.value(
        method,
        'method',
        'RPC names must start with "$kRpcNamespace" so they cannot collide '
            'with the framework\'s own service extensions',
      );
    }
    if (_handlers.containsKey(method)) {
      throw StateError('RPC "$method" is already registered');
    }
    _handlers[method] = handler;
  }

  Future<RpcResult> dispatch(
    String method,
    Map<String, String> params,
  ) async {
    final handler = _handlers[method];
    if (handler == null) {
      return RpcResult.error(
        jsonEncode({
          'error': 'unknownMethod',
          'message': 'No handler registered for "$method". This SDK serves: '
              '${methods.join(', ')}',
        }),
      );
    }

    try {
      return RpcResult.ok(jsonEncode(await handler(params)));
    } catch (error) {
      return RpcResult.error(
        jsonEncode({
          'error': error.runtimeType.toString(),
          'message': error.toString(),
        }),
      );
    }
  }
}
