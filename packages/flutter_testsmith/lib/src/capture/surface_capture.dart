import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A capture of the Flutter surface, and what is known about it.
@immutable
class SurfaceCapture {
  const SurfaceCapture({
    required this.pngBase64,
    required this.width,
    required this.height,
    required this.devicePixelRatio,
    required this.byteLength,
  });

  /// The image, base64-encoded because the VM Service carries JSON.
  final String pngBase64;

  /// Physical pixels, so the engine can compare with a device screencap
  /// without either side guessing at a convention.
  final int width;
  final int height;

  /// The ratio the capture was taken at, read at capture time rather
  /// than at attach - see risk R3b.
  final double devicePixelRatio;

  /// Decoded PNG length, so a caller can sanity-check the transfer
  /// without decoding base64 twice.
  final int byteLength;

  Map<String, Object?> toJson() => {
        'source': 'repaintBoundary',
        'width': width,
        'height': height,
        'devicePixelRatio': devicePixelRatio,
        'byteLength': byteLength,
        'pngBase64': pngBase64,
      };
}

/// Rasterises the Flutter surface from the render tree.
///
/// The second of the two capture paths the protocol has declared since
/// Phase 1, and the one nothing had ever emitted. What it produces is
/// **not** what `adb exec-out screencap` produces, and the difference is
/// not cosmetic:
///
/// * it contains only what Flutter painted - no status bar, no
///   navigation bar, no system dialog, no other application's window;
/// * it contains no platform view: a `WebView`, a map or a camera
///   preview is composited by the OS and is a hole in this image;
/// * it is taken from the layer tree rather than the framebuffer, so it
///   is unaffected by screen brightness, night mode, or a screen
///   recorder's overlay;
/// * its geometry is exactly `logical size x devicePixelRatio`, with no
///   OS scaling in between.
///
/// That makes it the better picture for comparing a screen with itself
/// over time, and it is still **not** a Figma render: see risk R7.
///
/// The engine records which path produced an image and refuses to diff
/// across the two, which is what makes having both safe.
Future<SurfaceCapture> captureSurface({double? pixelRatio}) async {
  final binding = WidgetsBinding.instance;
  final root = binding.rootElement;
  if (root == null) {
    throw StateError(
      'There is no widget tree to capture. Ask after runApp has produced '
      'a frame.',
    );
  }

  final renderObject = root.renderObject;
  if (renderObject is! RenderView) {
    throw StateError(
      'The root render object is a ${renderObject.runtimeType}, not a '
      'RenderView, so there is no surface to rasterise.',
    );
  }

  // RenderView's layer is an OffsetLayer whose transform already carries
  // the device pixel ratio, and its paintBounds are therefore in
  // physical pixels. Rasterising it at scale 1 gives exactly what the
  // engine composited - no resampling, and no second ratio to get wrong.
  final layer = renderObject.debugLayer;
  if (layer is! OffsetLayer) {
    throw StateError(
      'The root layer is a ${layer.runtimeType}; only an OffsetLayer can '
      'be rasterised. This usually means no frame has been painted yet.',
    );
  }

  final ratio = pixelRatio ?? renderObject.configuration.devicePixelRatio;
  final bounds = renderObject.paintBounds;

  final ui.Image image;
  try {
    image = await layer.toImage(bounds);
  } catch (error) {
    // Reported rather than thrown as something opaque: on a device
    // without a raster thread to serve the request this is where it
    // fails, and "toImage failed" with no context is unhelpful.
    throw StateError('the surface could not be rasterised: $error');
  }

  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('the rasterised surface could not be encoded as PNG');
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    return SurfaceCapture(
      pngBase64: base64Encode(bytes),
      width: image.width,
      height: image.height,
      devicePixelRatio: ratio,
      byteLength: bytes.length,
    );
  } finally {
    // Rasterised images hold native memory that the Dart GC does not
    // account for. A capture per validation, across a suite, is enough
    // for that to matter.
    image.dispose();
  }
}
