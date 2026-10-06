import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Records what the SDK would have sent, so session behaviour can be
/// asserted without a VM Service.
class FakeSdkChannel implements SdkChannel {
  final List<TestEvent> emitted = <TestEvent>[];
  final Map<String, RpcHandler> handlers = <String, RpcHandler>{};
  bool closed = false;

  @override
  void emit(TestEvent event) => emitted.add(event);

  @override
  void handle(String method, RpcHandler handler) {
    handlers[method] = handler;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, String> params = const {},
  ]) {
    final handler = handlers[method];
    if (handler == null) {
      throw StateError('No handler registered for "$method"');
    }
    return handler(params);
  }
}
