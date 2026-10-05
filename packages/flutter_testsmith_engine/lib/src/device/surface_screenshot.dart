import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Which picture of a screen to take.
///
/// The two are genuinely different pictures, not two qualities of the
/// same one, and the store refuses to diff across them. See ADR-0010.
enum CapturePath {
  /// `adb exec-out screencap`. The real device output: system bars,
  /// platform views, OS scaling and all.
  screencap('screencap', ScreenshotSource.deviceScreencap),

  /// `ext.mytest.screenshot`. Only what Flutter painted, at exactly
  /// logical size x devicePixelRatio.
  surface('surface', ScreenshotSource.repaintBoundary);

  const CapturePath(this.wire, this.source);

  final String wire;

  /// How the resulting image is labelled in the baseline metadata.
  final ScreenshotSource source;

  static CapturePath parse(String value, {required String source}) {
    for (final path in values) {
      if (path.wire == value) return path;
    }
    throw FormatException(
      '$source: unknown capture path "$value". '
      'Known: ${values.map((p) => p.wire).join(', ')}.',
    );
  }
}

/// The decoded reply from `ext.mytest.screenshot`.
@immutable
class SurfaceScreenshot {
  const SurfaceScreenshot({
    required this.bytes,
    required this.width,
    required this.height,
    required this.devicePixelRatio,
  });

  final Uint8List bytes;

  /// Physical pixels.
  final int width;
  final int height;

  final double devicePixelRatio;

  /// Reads the RPC reply, refusing anything that is not what it claims.
  ///
  /// Strict on purpose. A reply that decoded to an empty image would
  /// otherwise be recorded as a baseline, and every later run would
  /// compare against nothing.
  factory SurfaceScreenshot.fromRpc(Map<String, Object?> json) {
    final encoded = json['pngBase64'];
    if (encoded is! String || encoded.isEmpty) {
      throw FormatException(
        'ext.mytest.screenshot returned no image. Got keys: '
        '${json.keys.join(', ')}',
      );
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException(
        'ext.mytest.screenshot returned something that is not base64',
      );
    }

    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length) {
      throw const FormatException('the captured surface is empty');
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) {
        throw const FormatException(
          'the captured surface is not a PNG, so it was not recorded',
        );
      }
    }

    final declared = (json['byteLength'] as num?)?.toInt();
    if (declared != null && declared != bytes.length) {
      // A truncated transfer produces a decodable prefix, which would
      // then be compared as though it were the whole screen.
      throw FormatException(
        'the captured surface arrived truncated: the app sent $declared '
        'bytes and ${bytes.length} were decoded',
      );
    }

    return SurfaceScreenshot(
      bytes: bytes,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      devicePixelRatio: (json['devicePixelRatio'] as num?)?.toDouble() ?? 1,
    );
  }

  @override
  String toString() =>
      'SurfaceScreenshot(${width}x$height at $devicePixelRatio, '
      '${bytes.length} bytes)';
}
