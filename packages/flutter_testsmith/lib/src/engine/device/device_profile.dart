import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// A malformed device profile.
@immutable
class ProfileFormatException implements Exception {
  const ProfileFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'ProfileFormatException in $source: $message';
}

enum DeviceOrientation {
  portrait('portrait'),
  landscape('landscape');

  const DeviceOrientation(this.wire);

  final String wire;

  static DeviceOrientation? fromWire(Object? wire) {
    for (final value in values) {
      if (value.wire == wire) return value;
    }
    return null;
  }
}

/// What a connected device said about itself.
///
/// Every field is optional, and an absent one means *not reported*,
/// which is different from *disagrees*. A runner that cannot read the OS
/// has learned nothing about it, and must not turn that into a
/// mismatch.
@immutable
class DeviceFacts {
  const DeviceFacts({
    this.model,
    this.os,
    this.physicalWidth,
    this.physicalHeight,
    this.devicePixelRatio,
    this.buildMode,
  });

  final String? model;
  final String? os;
  final int? physicalWidth;
  final int? physicalHeight;
  final double? devicePixelRatio;
  final String? buildMode;

  /// Nothing was read from the device at all.
  ///
  /// The difference between *not reported* and *nothing to report from*.
  /// One absent field is silence about that field, and
  /// [DeviceProfile.mismatchesAgainst] rightly skips it. Every field
  /// absent is silence about the device, and skipping all of them leaves
  /// an empty mismatch list that reads exactly like agreement - which is
  /// how a profile came to be reported satisfied against a handset
  /// nobody had read a single fact from.
  ///
  /// Exact rather than approximate: `readDeviceFacts` is the only
  /// producer, and a reading it completed can never look like this. It
  /// sets `os` by interpolation and the two dimensions through
  /// `int.parse(... ?? '0')`, so all six are null only on the paths that
  /// read nothing - adb throwing, or the serial not being attached.
  bool get reportedNothing =>
      model == null &&
      os == null &&
      physicalWidth == null &&
      physicalHeight == null &&
      devicePixelRatio == null &&
      buildMode == null;
}

/// The runtime environment a baseline belongs to.
///
/// **Not a serial number.** `RZ8T11QETWM` identifies the handset on one
/// desk; it says nothing about the conditions a picture was recorded
/// under, and binding a baseline to it would mean the baseline could
/// only ever be checked on the machine that took it - the opposite of
/// what a committed baseline is for.
///
/// What makes two runs comparable is the model, the OS, the resolution,
/// the pixel ratio, the orientation and the build mode. A profile names
/// those, is stable across every device of that kind, and is chosen by a
/// person rather than discovered - so it can be written into a baseline
/// path and reviewed like any other file.
///
/// The application's own version is deliberately **not** here. It
/// changes with every build; declaring it would make the profile a thing
/// somebody has to maintain, and a maintained provenance note is a stale
/// one. It is read from the handshake and recorded instead.
@immutable
class DeviceProfile {
  const DeviceProfile({
    required this.id,
    this.model,
    this.os,
    this.physicalWidth,
    this.physicalHeight,
    this.devicePixelRatio,
    this.orientation = DeviceOrientation.portrait,
    this.buildMode,
  });

  /// The stable identity. Chosen, reviewed, and written into paths.
  final String id;

  final String? model;
  final String? os;

  /// Physical pixels, as the device reports them.
  final int? physicalWidth;
  final int? physicalHeight;

  final double? devicePixelRatio;
  final DeviceOrientation orientation;
  final String? buildMode;

  /// Logical pixels, derived rather than declared.
  ///
  /// Two numbers that must agree are one number and an opportunity to
  /// get it wrong.
  double? get logicalWidth => _logical(physicalWidth);
  double? get logicalHeight => _logical(physicalHeight);

  double? _logical(int? physical) {
    final ratio = devicePixelRatio;
    if (physical == null || ratio == null || ratio <= 0) return null;
    return physical / ratio;
  }

  static const Set<String> _keys = {
    'id',
    'model',
    'os',
    'physical',
    'devicePixelRatio',
    'orientation',
    'buildMode',
  };

  factory DeviceProfile.parse(String yamlText, {required String source}) {
    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      throw ProfileFormatException(source, 'invalid YAML: ${error.message}');
    }
    if (loaded is! Map) {
      throw ProfileFormatException(
        source,
        'expected a mapping at the root with at least an id',
      );
    }

    final root = loaded.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );

    for (final key in root.keys) {
      if (_keys.contains(key)) continue;
      throw ProfileFormatException(
        source,
        'unknown key "$key". Known: ${_keys.join(', ')}.',
      );
    }

    final id = root['id'];
    if (id is! String || id.isEmpty) {
      throw ProfileFormatException(
        source,
        'a profile needs an "id": it is the name a baseline is filed '
        'under, and it must not be a device serial.',
      );
    }

    int? dimension(Map<String, Object?> box, String key) {
      final value = box[key];
      if (value == null) return null;
      if (value is! num || value <= 0) {
        throw ProfileFormatException(
          source,
          '"physical.$key" must be a positive number of pixels',
        );
      }
      return value.toInt();
    }

    final rawPhysical = root['physical'];
    if (rawPhysical != null && rawPhysical is! Map) {
      throw ProfileFormatException(
        source,
        '"physical" must be a mapping of width and height',
      );
    }
    final physical = (rawPhysical as Map?)
            ?.cast<Object?, Object?>()
            .map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, Object?>{};

    final rawRatio = root['devicePixelRatio'];
    if (rawRatio != null && (rawRatio is! num || rawRatio <= 0)) {
      throw ProfileFormatException(
        source,
        '"devicePixelRatio" must be a positive number',
      );
    }

    final rawOrientation = root['orientation'];
    final orientation = rawOrientation == null
        ? DeviceOrientation.portrait
        : DeviceOrientation.fromWire(rawOrientation);
    if (orientation == null) {
      throw ProfileFormatException(
        source,
        'unknown orientation "$rawOrientation". Known: '
        '${DeviceOrientation.values.map((o) => o.wire).join(', ')}.',
      );
    }

    return DeviceProfile(
      id: id,
      model: root['model']?.toString(),
      os: root['os']?.toString(),
      physicalWidth: dimension(physical, 'width'),
      physicalHeight: dimension(physical, 'height'),
      devicePixelRatio: (rawRatio as num?)?.toDouble(),
      orientation: orientation,
      buildMode: root['buildMode']?.toString(),
    );
  }

  /// Every way [facts] disagrees with what this profile declares.
  ///
  /// Empty means the connected device is the one the profile describes.
  /// A fact the device did not report is not a disagreement.
  List<String> mismatchesAgainst(DeviceFacts facts) {
    final mismatches = <String>[];

    void compare(String what, Object? declared, Object? actual) {
      if (declared == null || actual == null) return;
      if (declared == actual) return;
      mismatches.add(
        'the profile declares $what $declared but the device reports $actual',
      );
    }

    compare('model', model, facts.model);
    compare('os', os, facts.os);
    compare('devicePixelRatio', devicePixelRatio, facts.devicePixelRatio);
    compare('buildMode', buildMode, facts.buildMode);

    final declaredSize = _size(physicalWidth, physicalHeight);
    final actualSize = _size(facts.physicalWidth, facts.physicalHeight);
    compare('a physical resolution of', declaredSize, actualSize);

    return mismatches;
  }

  static String? _size(int? width, int? height) =>
      width == null || height == null ? null : '${width}x$height';

  Map<String, Object?> toJson() => {
        'id': id,
        if (model != null) 'model': model,
        if (os != null) 'os': os,
        if (physicalWidth != null && physicalHeight != null)
          'physical': {'width': physicalWidth, 'height': physicalHeight},
        if (devicePixelRatio != null) 'devicePixelRatio': devicePixelRatio,
        'orientation': orientation.wire,
        if (buildMode != null) 'buildMode': buildMode,
      };

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile &&
      other.id == id &&
      other.model == model &&
      other.os == os &&
      other.physicalWidth == physicalWidth &&
      other.physicalHeight == physicalHeight &&
      other.devicePixelRatio == devicePixelRatio &&
      other.orientation == orientation &&
      other.buildMode == buildMode;

  @override
  int get hashCode => Object.hash(
        id,
        model,
        os,
        physicalWidth,
        physicalHeight,
        devicePixelRatio,
        orientation,
        buildMode,
      );

  @override
  String toString() => 'DeviceProfile($id)';
}
