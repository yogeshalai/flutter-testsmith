import 'package:meta/meta.dart';

import 'errors.dart';
import 'json.dart';

/// How the application under test was built.
enum BuildMode {
  debug('debug'),
  profile('profile'),
  release('release');

  const BuildMode(this.wire);

  final String wire;

  static BuildMode fromWire(String wire) {
    for (final mode in BuildMode.values) {
      if (mode.wire == wire) return mode;
    }
    throw ProtocolFormatException('Unknown build mode "$wire"');
  }
}

/// Identity of the application emitting an event.
///
/// [devicePixelRatio] lives here rather than being fetched separately because
/// every logical-to-physical coordinate conversion depends on it, and a
/// conversion performed against a stale or assumed ratio produces silently
/// wrong tap positions.
@immutable
class AppContext {
  const AppContext({
    required this.appVersion,
    required this.buildMode,
    required this.environment,
    required this.platform,
    required this.devicePixelRatio,
  });

  final String appVersion;
  final BuildMode buildMode;
  final String environment;
  final String platform;
  final double devicePixelRatio;

  Map<String, Object?> toJson() => {
        'appVersion': appVersion,
        'buildMode': buildMode.wire,
        'environment': environment,
        'platform': platform,
        'devicePixelRatio': devicePixelRatio,
      };

  factory AppContext.fromJson(Map<String, Object?> json) => AppContext(
        appVersion: json.required<String>('appVersion'),
        buildMode: BuildMode.fromWire(json.required<String>('buildMode')),
        environment: json.required<String>('environment'),
        platform: json.required<String>('platform'),
        devicePixelRatio: json.requiredDouble('devicePixelRatio'),
      );

  @override
  bool operator ==(Object other) =>
      other is AppContext &&
      other.appVersion == appVersion &&
      other.buildMode == buildMode &&
      other.environment == environment &&
      other.platform == platform &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(
        appVersion,
        buildMode,
        environment,
        platform,
        devicePixelRatio,
      );

  @override
  String toString() =>
      'AppContext($appVersion, ${buildMode.wire}, $environment, $platform, '
      'dpr=$devicePixelRatio)';
}
