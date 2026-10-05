import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

void main() {
  group('RpcDispatcher', () {
    test('encodes a handler result as JSON', () async {
      final dispatcher = RpcDispatcher()
        ..register('ext.mytest.ping', (params) async => {'pong': true});

      final result = await dispatcher.dispatch('ext.mytest.ping', const {});

      expect(result.isError, isFalse);
      expect(jsonDecode(result.body), {'pong': true});
    });

    test('passes parameters through to the handler', () async {
      final dispatcher = RpcDispatcher()
        ..register(
          'ext.mytest.echo',
          (params) async => {'got': params['value']},
        );

      final result =
          await dispatcher.dispatch('ext.mytest.echo', {'value': 'x'});

      expect(jsonDecode(result.body), {'got': 'x'});
    });

    test('reports an unknown method as an error naming it', () async {
      final dispatcher = RpcDispatcher();

      final result = await dispatcher.dispatch('ext.mytest.nope', const {});

      expect(result.isError, isTrue);
      expect(result.body, contains('ext.mytest.nope'));
    });

    test('turns a protocol version mismatch into a readable error', () async {
      // The engine sees this as a failed RPC rather than a hung connection,
      // and the message has to say what to do about it.
      final dispatcher = RpcDispatcher()
        ..register(
          'ext.mytest.handshake',
          (params) async => throw const ProtocolVersionMismatch(
            expected: ProtocolVersion(1, 0),
            received: ProtocolVersion(2, 0),
          ),
        );

      final result =
          await dispatcher.dispatch('ext.mytest.handshake', const {});

      expect(result.isError, isTrue);
      expect(result.body, contains('Major versions must match'));
    });

    test('turns any handler exception into an error rather than hanging',
        () async {
      final dispatcher = RpcDispatcher()
        ..register(
          'ext.mytest.boom',
          (params) async => throw StateError('kaboom'),
        );

      final result = await dispatcher.dispatch('ext.mytest.boom', const {});

      expect(result.isError, isTrue);
      expect(result.body, contains('kaboom'));
    });

    test('rejects a method outside the ext.mytest namespace', () {
      // Namespacing prevents collision with Flutter's own service
      // extensions, so it is enforced rather than merely documented.
      expect(
        () => RpcDispatcher().register('ext.flutter.evil', (p) async => {}),
        throwsArgumentError,
      );
    });

    test('rejects registering the same method twice', () {
      final dispatcher = RpcDispatcher()
        ..register('ext.mytest.ping', (p) async => {});

      expect(
        () => dispatcher.register('ext.mytest.ping', (p) async => {}),
        throwsStateError,
      );
    });

    test('lists what it serves', () {
      final dispatcher = RpcDispatcher()
        ..register('ext.mytest.ping', (p) async => {})
        ..register('ext.mytest.pong', (p) async => {});

      expect(dispatcher.methods, {'ext.mytest.ping', 'ext.mytest.pong'});
    });
  });
}
