import 'package:meta/meta.dart';

import 'version.dart';

/// Thrown when a payload cannot be read as a protocol message.
///
/// The message always names the offending field or value, because a decode
/// failure that says only "invalid JSON" costs more to diagnose than the bug
/// it is reporting.
@immutable
class ProtocolFormatException implements Exception {
  const ProtocolFormatException(this.message);

  final String message;

  @override
  String toString() => 'ProtocolFormatException: $message';
}

/// Thrown when the peer speaks an incompatible major protocol version.
///
/// This is deliberately a hard failure rather than a degraded mode: a
/// mismatched protocol produces wrong test results, which is worse than a
/// refusal to run.
@immutable
class ProtocolVersionMismatch implements Exception {
  const ProtocolVersionMismatch({
    required this.expected,
    required this.received,
  });

  final ProtocolVersion expected;
  final ProtocolVersion received;

  @override
  String toString() =>
      'ProtocolVersionMismatch: this build speaks protocol $expected but the '
      'peer speaks $received. Major versions must match. Update whichever '
      'side is older so both use protocol ${expected.major}.x.';
}
