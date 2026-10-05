import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:meta/meta.dart';

/// One structured event from `flutter run --machine`.
///
/// The tool emits these as a single-element JSON array per line, freely
/// interleaved with human-readable build output and forwarded logcat.
@immutable
class FlutterMachineEvent {
  const FlutterMachineEvent(this.event, this.params);

  final String event;
  final Map<String, Object?> params;

  /// Parses [line], or returns null if it is not a machine event.
  ///
  /// Never throws. Build noise, logcat, blank lines and a truncated line
  /// from an interrupted process are all simply "not an event"; losing a
  /// whole run because a cosmetic line failed to parse would be absurd.
  static FlutterMachineEvent? tryParse(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }

    if (decoded is! List || decoded.length != 1) return null;
    final entry = decoded.first;
    if (entry is! Map) return null;

    final name = entry['event'];
    if (name is! String) return null;

    final params = entry['params'];
    return FlutterMachineEvent(
      name,
      params is Map ? params.cast<String, Object?>() : const {},
    );
  }

  @override
  String toString() => 'FlutterMachineEvent($event, $params)';
}

/// Tracks the state of one `flutter run --machine` process.
///
/// Feed it stdout lines; it extracts the app id, the device, and the VM
/// Service websocket URI, and reports when the application is actually
/// running.
class FlutterRunSession {
  final Completer<Uri> _ready = Completer<Uri>();

  String? _appId;
  String? _deviceId;
  Uri? _vmServiceUri;
  bool _started = false;
  bool _stopped = false;

  String? get appId => _appId;
  String? get deviceId => _deviceId;
  bool get hasStopped => _stopped;

  /// What flutter said went wrong, oldest first.
  ///
  /// `flutter run --machine` reports most failures here rather than on
  /// stderr: a Gradle error, a missing entry point, an unknown flavour
  /// arrive as `daemon.logMessage` at level "error", and a start that
  /// failed as `app.stop` carrying `error`. Only those. Status and trace
  /// messages are progress, not reasons, and `app.stop`'s `trace` is
  /// flutter_tools' own stack, which tells the reader nothing about
  /// their application.
  ///
  /// Bounded, because a build can repeat an error for as long as it
  /// runs: the newest [maxFailureReasons], each cut to
  /// [maxFailureReasonLength]. The newest are kept because the last
  /// thing said before an exit is the likeliest cause.
  List<String> get failureReasons => List.unmodifiable(_reasons);

  static const int maxFailureReasons = 20;
  static const int maxFailureReasonLength = 1000;

  final ListQueue<String> _reasons = ListQueue<String>();

  void _keepReason(Object? message) {
    if (message is! String) return;
    var text = message.trim();
    if (text.isEmpty) return;
    if (text.length > maxFailureReasonLength) {
      text = '${text.substring(0, maxFailureReasonLength)}...';
    }
    // The same sentence twice in a row is one reason.
    if (_reasons.isNotEmpty && _reasons.last == text) return;
    _reasons.add(text);
    while (_reasons.length > maxFailureReasons) {
      _reasons.removeFirst();
    }
  }

  /// True once the VM Service URI is known **and** the app has started.
  ///
  /// Both matter: a debug port is published before the application is
  /// running, and attaching then races the isolate's startup.
  bool get isReady => _vmServiceUri != null && _started;

  /// Completes with the VM Service URI once [isReady].
  Future<Uri> get onReady => _ready.future;

  Uri get vmServiceUri {
    final uri = _vmServiceUri;
    if (uri == null) {
      throw StateError(
        'The VM Service URI is not known yet. flutter run publishes it in '
        'an app.debugPort event; await onReady before reading it.',
      );
    }
    return uri;
  }

  void consume(String line) {
    final event = FlutterMachineEvent.tryParse(line);
    if (event == null) return;

    switch (event.event) {
      case 'app.start':
        _appId = event.params['appId'] as String?;
        _deviceId = event.params['deviceId'] as String?;
      case 'app.debugPort':
        final wsUri = event.params['wsUri'];
        if (wsUri is String) _vmServiceUri = Uri.parse(wsUri);
      case 'app.started':
        _started = true;
      case 'app.stop':
        _stopped = true;
        _keepReason(event.params['error']);
      case 'daemon.logMessage':
        if (event.params['level'] == 'error') {
          _keepReason(event.params['message']);
        }
    }

    if (isReady && !_ready.isCompleted) {
      _ready.complete(_vmServiceUri);
    }
  }
}
