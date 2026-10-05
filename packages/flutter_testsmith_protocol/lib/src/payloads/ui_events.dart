part of '../payloads.dart';

/// Emitted when the UI tree is captured.
///
/// Capture is pull-based: the engine asks via `ext.mytest.uiTree`. The
/// event exists so the capture also lands in the session history and can
/// be correlated with the API calls and screenshot for that screen. The
/// tree is never emitted per frame - see ARCHITECTURE 14.
final class WidgetTreePayload extends EventPayload {
  const WidgetTreePayload({required this.snapshot});

  final UiSnapshot snapshot;

  @override
  EventType get type => EventType.widgetTree;

  @override
  Map<String, Object?> toJson() => {'snapshot': snapshot.toJson()};

  factory WidgetTreePayload.fromJson(Map<String, Object?> json) =>
      WidgetTreePayload(
        snapshot: UiSnapshot.fromJson(json.requiredMap('snapshot')),
      );

  @override
  String toString() => 'WidgetTreePayload($snapshot)';
}

/// How a screenshot was produced.
///
/// The two paths do not produce identical images: a RepaintBoundary
/// capture is the Flutter surface at exact logical geometry with no system
/// UI, while a device screencap is the real screen including the status
/// bar. Diffing across paths is meaningless, so the source travels with
/// the image and comparison refuses to mix them. See risk R5.
enum ScreenshotSource {
  repaintBoundary('repaintBoundary'),
  deviceScreencap('deviceScreencap');

  const ScreenshotSource(this.wire);

  final String wire;

  static ScreenshotSource fromWire(String wire) {
    for (final source in ScreenshotSource.values) {
      if (source.wire == wire) return source;
    }
    throw ProtocolFormatException('Unknown screenshot source "$wire"');
  }
}

/// Emitted when a screenshot is captured.
///
/// Carries metadata only. Image bytes travel out of band, because a
/// base64 PNG inside every event would bloat the session history for no
/// benefit.
final class ScreenshotPayload extends EventPayload {
  const ScreenshotPayload({
    required this.source,
    required this.width,
    required this.height,
    required this.byteLength,
    this.path,
  });

  final ScreenshotSource source;

  /// Physical pixels.
  final int width;
  final int height;

  final int byteLength;

  /// Where the engine stored the image, when it did.
  final String? path;

  @override
  EventType get type => EventType.screenshot;

  @override
  Map<String, Object?> toJson() => {
        'source': source.wire,
        'width': width,
        'height': height,
        'byteLength': byteLength,
        if (path != null) 'path': path,
      };

  factory ScreenshotPayload.fromJson(Map<String, Object?> json) =>
      ScreenshotPayload(
        source: ScreenshotSource.fromWire(json.required<String>('source')),
        width: json.required<int>('width'),
        height: json.required<int>('height'),
        byteLength: json.required<int>('byteLength'),
        path: json.optional<String>('path'),
      );

  @override
  String toString() =>
      'ScreenshotPayload(${source.wire}, ${width}x$height, $byteLength bytes)';
}
