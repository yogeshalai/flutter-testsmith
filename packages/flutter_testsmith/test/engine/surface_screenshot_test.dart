import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// A minimal but real 1x1 PNG.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
  'IQAAAABJRU5ErkJggg==',
);

Map<String, Object?> reply({
  String? png,
  int? byteLength,
  int width = 1,
  int height = 1,
}) =>
    {
      'source': 'repaintBoundary',
      'width': width,
      'height': height,
      'devicePixelRatio': 2.0,
      'byteLength': byteLength ?? onePixelPng.length,
      'pngBase64': png ?? base64Encode(onePixelPng),
    };

void main() {
  group('SurfaceScreenshot.fromRpc', () {
    test('decodes a PNG and its geometry', () {
      final shot = SurfaceScreenshot.fromRpc(reply(width: 720, height: 1509));

      expect(shot.width, 720);
      expect(shot.height, 1509);
      expect(shot.devicePixelRatio, 2.0);
      expect(shot.bytes, onePixelPng);
    });

    test('refuses a reply with no image', () {
      expect(
        () => SurfaceScreenshot.fromRpc({'width': 1, 'height': 1}),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses something that is not a PNG', () {
      // Otherwise it would be recorded as a baseline and every later run
      // would compare against nothing.
      expect(
        () => SurfaceScreenshot.fromRpc(
          reply(png: base64Encode(utf8.encode('not an image')), byteLength: 12),
        ),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('not a PNG')),
        ),
      );
    });

    test('refuses a truncated transfer', () {
      // A truncated PNG still decodes to a prefix, which would then be
      // compared as though it were the whole screen.
      expect(
        () => SurfaceScreenshot.fromRpc(reply(byteLength: 99999)),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('truncated')),
        ),
      );
    });
  });

  group('CapturePath', () {
    test('each path names the source the baseline records', () {
      expect(CapturePath.screencap.source, ScreenshotSource.deviceScreencap);
      expect(CapturePath.surface.source, ScreenshotSource.repaintBoundary);
    });

    test('an unknown path is a configuration error, not a default', () {
      // Silently defaulting would compare a surface capture against a
      // screencap baseline.
      expect(
        () => CapturePath.parse('screenshot', source: 'x.yaml'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('visual config', () {
    test('defaults to screencap, which every committed baseline used', () {
      expect(VisualCheckConfig.defaults.capture, CapturePath.screencap);
    });

    test('reads capture: surface', () {
      final config = VisualCheckConfig.fromYaml(
        {'capture': 'surface'},
        source: 'x.yaml',
      );

      expect(config.capture, CapturePath.surface);
    });

    test('rejects an unknown capture path', () {
      expect(
        () => VisualCheckConfig.fromYaml(
          {'capture': 'magic'},
          source: 'x.yaml',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
