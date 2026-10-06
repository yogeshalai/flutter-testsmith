import 'package:meta/meta.dart';

/// A `major.minor` protocol version.
///
/// Compatibility is decided by the major component alone: the protocol never
/// silently degrades across a breaking change, because a degraded protocol
/// produces wrong test results rather than an obvious error.
@immutable
class ProtocolVersion {
  const ProtocolVersion(this.major, this.minor);

  /// The version this build of the protocol speaks.
  static const ProtocolVersion current = ProtocolVersion(1, 0);

  final int major;
  final int minor;

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)$');

  factory ProtocolVersion.parse(String source) {
    final match = _pattern.firstMatch(source);
    if (match == null) {
      throw FormatException(
        'Protocol version must be "major.minor" (for example "1.0")',
        source,
      );
    }
    return ProtocolVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
    );
  }

  String get value => '$major.$minor';

  bool isCompatibleWith(ProtocolVersion other) => major == other.major;

  @override
  bool operator ==(Object other) =>
      other is ProtocolVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => value;
}
