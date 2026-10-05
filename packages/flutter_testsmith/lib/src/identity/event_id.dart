import 'dart:math';

final Random _random = Random.secure();

/// Generates a random RFC 4122 version 4 UUID.
///
/// Hand-rolled rather than taking a dependency: `flutter_testsmith_protocol` and this SDK
/// are linked into production applications, so every dependency added here
/// becomes a dependency of every application under test.
String generateUuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

  // Version 4, variant 10xx.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int start, int end) => [
        for (var i = start; i < end; i++)
          bytes[i].toRadixString(16).padLeft(2, '0'),
      ].join();

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
