import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../device/device_profile.dart';

/// A recorded screenshot and what is known about how it was taken.
@immutable
class Baseline {
  const Baseline({
    required this.bytes,
    required this.source,
    required this.width,
    required this.height,
    required this.recordedAt,
    this.devicePixelRatio,
  });

  final Uint8List bytes;

  /// How the image was captured.
  ///
  /// Kept because a `RepaintBoundary` image and a device `screencap` of
  /// the same screen are not the same picture - one has the status bar
  /// and navigation bar in it, the other does not. Diffing across the
  /// two reports a change that never happened, so the store refuses to.
  /// See risk R5.
  final ScreenshotSource source;

  final int width;
  final int height;
  final DateTime recordedAt;

  /// The ratio the picture was taken at, when the file records one.
  ///
  /// Read back rather than merely written: a baseline taken at 1.875 and
  /// compared at 3.0 differs everywhere, and knowing that is how the
  /// comparison can refuse instead of reporting a regression.
  final double? devicePixelRatio;

  Map<String, Object?> get metadata => {
        'source': source.wire,
        'width': width,
        'height': height,
        'recordedAt': formatUtcTimestamp(recordedAt),
      };
}

/// What a baseline was recorded against.
///
/// A baseline is a picture somebody accepted, and six months later the
/// only question asked about a failing one is "what was this recorded
/// on?". The file used to answer with a capture source, a size and a
/// timestamp - enough to refuse an incompatible comparison, not enough
/// to reproduce the recording.
///
/// **Recorded, not enforced.** A size mismatch already refuses a
/// comparison across two geometries, which is the case that produces a
/// wrong answer. Making the device serial a precondition would mean a
/// baseline could only ever be checked on the machine that took it,
/// which is the opposite of what a committed baseline is for.
///
/// Every field is optional, and an absent one is left out of the file
/// rather than written as null: a runner that cannot name the OS must
/// not record a guess at it.
@immutable
class BaselineEnvironment {
  const BaselineEnvironment({
    this.device,
    this.deviceModel,
    this.osVersion,
    this.appVersion,
    this.buildMode,
    this.devicePixelRatio,
  });

  /// The device serial the picture was taken on.
  final String? device;

  /// The hardware model, which is what a reader actually recognises.
  final String? deviceModel;

  final String? osVersion;

  /// The application's own version, as it reported at handshake.
  final String? appVersion;

  final String? buildMode;

  /// Logical-to-physical ratio at capture. A baseline taken at 1.875
  /// and compared at 3.0 differs everywhere, and the size check catches
  /// it - this says why.
  final double? devicePixelRatio;

  bool get isEmpty =>
      device == null &&
      deviceModel == null &&
      osVersion == null &&
      appVersion == null &&
      buildMode == null &&
      devicePixelRatio == null;

  Map<String, Object?> toJson() => {
        if (device != null) 'device': device,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (osVersion != null) 'osVersion': osVersion,
        if (appVersion != null) 'appVersion': appVersion,
        if (buildMode != null) 'buildMode': buildMode,
        if (devicePixelRatio != null) 'devicePixelRatio': devicePixelRatio,
      };
}

/// The pixel dimensions in a PNG's header, or null if it is not a PNG.
///
/// Read from the 8-byte signature plus IHDR rather than by decoding:
/// recording a baseline should not spend a second inflating a few
/// million pixels just to learn how wide the image is.
({int width, int height})? pngDimensions(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }

  final data = ByteData.sublistView(bytes);
  return (
    width: data.getUint32(16),
    height: data.getUint32(20),
  );
}

/// Which recorded picture a run may compare against.
///
/// Four outcomes, and deliberately no fifth. There is no "closest
/// match": the closest match to a picture of a different device is still
/// a picture of a different device, and comparing against it reports a
/// screen that has not changed as different in every pixel - which is
/// true, and useless, and was measured before this existed.
sealed class BaselineSelection {
  const BaselineSelection();
}

/// Exactly one candidate, and it belongs to this profile.
@immutable
final class BaselineSelected extends BaselineSelection {
  const BaselineSelected({
    required this.baseline,
    required this.path,
    required this.isLegacyPath,
  });

  final Baseline baseline;
  final String path;

  /// Whether it came from the flat pre-profile layout.
  ///
  /// Worth reporting rather than hiding: it resolved, and it is also a
  /// baseline nobody has filed under a profile yet.
  final bool isLegacyPath;
}

/// No candidate anywhere.
@immutable
final class BaselineMissing extends BaselineSelection {
  const BaselineMissing(this.searched);

  /// Every path that was looked at, so the answer is actionable.
  final List<String> searched;
}

/// More than one candidate. Choosing would be guessing.
@immutable
final class BaselineAmbiguous extends BaselineSelection {
  const BaselineAmbiguous(this.paths);

  final List<String> paths;
}

/// Found, but recorded under conditions that make the comparison
/// meaningless.
@immutable
final class BaselineIncompatible extends BaselineSelection {
  const BaselineIncompatible({required this.path, required this.reasons});

  final String path;
  final List<String> reasons;
}

/// Reads and writes accepted screenshots on disk.
///
/// Baselines are files in the repository, reviewed like any other
/// change. Nothing here accepts a new image on its own: a screenshot
/// that differs is a finding until a person says otherwise, and a store
/// that silently re-baselines is a test suite that can never fail
/// twice.
class BaselineStore {
  const BaselineStore(
    this.directory, {
    this.variant,
    this.profile,
    this.environment = const BaselineEnvironment(),
  });

  final Directory directory;

  /// The device profile this run is executing under, when there is one.
  ///
  /// Null for `testsmith run`, which has no suite and therefore no profile;
  /// selection then behaves exactly as it did before profiles existed.
  final DeviceProfile? profile;

  /// The API state this store's baselines were recorded under.
  ///
  /// A screen does not look the same under every fixture, and that is
  /// not a regression: the out-of-stock product screen carries a line
  /// the in-stock one does not, which moves everything below it.
  /// Measured on the device before this existed - the out-of-stock run
  /// reported 2.028% of the screen differing against the in-stock
  /// baseline, correctly and uselessly.
  ///
  /// Null means the default state, and keeps the plain file name, so
  /// every baseline recorded before variants existed still resolves.
  final String? variant;

  /// The device and build this store's baselines were recorded on.
  ///
  /// Written into the metadata beside each picture. Empty when the
  /// caller could not say, and then nothing is written - which keeps a
  /// re-recorded baseline byte-identical to one from before this
  /// existed.
  final BaselineEnvironment environment;

  /// Where a baseline recorded by *this* run belongs.
  ///
  /// Under the profile when there is one, flat when there is not. A
  /// picture is filed where it can later be found by something that
  /// knows what it was taken on.
  File imageFile(String screenId) => File('${_writePrefix(screenId)}.png');

  File metadataFile(String screenId) => File('${_writePrefix(screenId)}.json');

  String _writePrefix(String screenId) {
    final name = fileNameFor(screenId, variant);
    final id = profile?.id;
    return id == null
        ? '${directory.path}/$name'
        : '${directory.path}/$id/$name';
  }

  /// The paths a baseline for [screenId] could legitimately live at, in
  /// no particular order - because there is no preference between them.
  List<String> candidatePaths(String screenId) {
    final name = fileNameFor(screenId, variant);
    final id = profile?.id;
    return [
      if (id != null) '${directory.path}/$id/$name',
      '${directory.path}/$name',
    ];
  }

  /// Chooses the one baseline this run may compare against.
  ///
  /// See [BaselineSelection]: exactly one candidate is selected, two is
  /// ambiguous, none is missing, and one recorded under a different
  /// resolution or pixel ratio is incompatible. Nothing here picks a
  /// nearest neighbour.
  Future<BaselineSelection> select(String screenId) async {
    final candidates = candidatePaths(screenId);
    final present = [
      for (final path in candidates)
        if (File('$path.png').existsSync()) path,
    ];

    if (present.isEmpty) return BaselineMissing(candidates);
    if (present.length > 1) return BaselineAmbiguous(present);

    final path = present.single;
    final baseline = await _readAt(path);

    final reasons = _incompatibilities(baseline, path);
    if (reasons.isNotEmpty) {
      return BaselineIncompatible(path: path, reasons: reasons);
    }

    return BaselineSelected(
      baseline: baseline,
      path: path,
      isLegacyPath: path == candidates.last && candidates.length > 1,
    );
  }

  /// Why [baseline] cannot be compared against under this profile.
  ///
  /// Resolution and pixel ratio only. Those are the two that make the
  /// comparison arithmetically wrong; a model or OS difference at the
  /// same geometry is recorded in the metadata and surfaced in the
  /// report, but it does not by itself make two pictures incomparable.
  List<String> _incompatibilities(Baseline baseline, String path) {
    final profile = this.profile;
    if (profile == null) return const [];

    final reasons = <String>[];

    final width = profile.physicalWidth;
    final height = profile.physicalHeight;
    if (width != null &&
        height != null &&
        (baseline.width != width || baseline.height != height)) {
      reasons.add(
        'it was recorded at ${baseline.width}x${baseline.height} and this '
        'profile is ${width}x$height',
      );
    }

    final ratio = profile.devicePixelRatio;
    final recorded = baseline.devicePixelRatio;
    if (ratio != null && recorded != null && recorded != ratio) {
      reasons.add(
        'it was recorded at a device pixel ratio of $recorded and this '
        'profile is $ratio',
      );
    }

    return reasons;
  }

  /// A screen id turned into something a filesystem accepts.
  ///
  /// `/product/details` becomes `product_details`, and with a variant,
  /// `product_details@product_out_of_stock`. Case is preserved but
  /// separators are not, so two screens differing only by separator
  /// would collide - which is why the metadata records the screen id
  /// and a mismatch is reported rather than assumed.
  static String fileNameFor(String screenId, [String? variant]) {
    String clean(String value) => value
        .replaceAll(RegExp(r'^[/\\]+'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

    final base = clean(screenId);
    final name = base.isEmpty ? 'screen' : base;
    if (variant == null || variant.isEmpty) return name;
    return '$name@${clean(variant)}';
  }

  /// The baseline for [screenId], or null when there is none.
  ///
  /// Kept for callers that only need "is there one": selection is what
  /// decides whether a run may *compare* against it.
  Future<Baseline?> read(String screenId) async {
    for (final path in candidatePaths(screenId)) {
      if (File('$path.png').existsSync()) return _readAt(path);
    }
    return null;
  }

  /// The recorded picture at [path], or a [StateError] saying why not.
  ///
  /// One currency for every way this read can fail, because there is one
  /// caller and it already decided what a refusal means: `_compare`
  /// catches `StateError` and reports a visual ERROR, the same outcome
  /// two candidates and incompatible hardware get. An ERROR rather than
  /// a FAIL, because a metadata file nobody can read says nothing about
  /// the screen.
  ///
  /// Only the absent file raised one. The fields were read with `!` and
  /// `as`, so a committed file that was valid JSON and wrong left here
  /// as a `_TypeError`, and one that was not JSON at all as a bare
  /// `FormatException` - neither of which is a `StateError`, so neither
  /// reached that guard. Measured against 9428a0f: ten ways of being
  /// wrong, three exception types, none naming the file or the field.
  ///
  /// `c9c4532` removed the same defect from figma specs, which are the
  /// other committed JSON artefact a run reads. This one is more
  /// exposed, not less: a baseline is re-recorded by two people and
  /// merged.
  Future<Baseline> _readAt(String path) async {
    final image = File('$path.png');
    final bytes = await image.readAsBytes();
    final meta = File('$path.json');

    if (!meta.existsSync()) {
      // An image with no metadata predates, or lost, its record of how
      // it was captured. Refusing is safer than guessing the source.
      throw StateError(
        'the baseline ${image.path} has no ${meta.path} beside it, so how '
        'it was captured is unknown. Delete it and re-record.',
      );
    }

    // The same sentence as above, in the same voice: what is wrong, and
    // what to do about it. Correcting the file is offered first because
    // a baseline is an accepted picture, and re-recording throws that
    // acceptance away to fix a typo.
    Never bad(String problem) => throw StateError(
          'the baseline metadata ${meta.path} $problem Correct it, or '
          'delete ${image.path} and re-record.',
        );

    final Object? decoded;
    try {
      decoded = jsonDecode(await meta.readAsString());
    } on FormatException catch (error) {
      bad('is not readable JSON: ${error.message}.');
    }
    if (decoded is! Map) {
      bad('is not an object recording "source", "width", "height" and '
          '"recordedAt".');
    }
    final json = decoded.cast<String, Object?>();

    int pixels(String key) {
      final value = json[key];
      if (value == null) bad('records no "$key".');
      if (value is! num) {
        bad('records "$key" as "$value", which is not a whole number of '
            'pixels.');
      }
      return value.toInt();
    }

    final rawSource = json['source'];
    if (rawSource is! String) {
      bad(rawSource == null
          ? 'records no "source", so how the picture was captured is '
              'unknown.'
          : 'records "source" as "$rawSource", which is not the name of a '
              'capture path.');
    }
    final ScreenshotSource source;
    try {
      // Reused rather than restated: the wire names belong to the
      // protocol, and a second copy of them here would be a second
      // answer to what a capture path is called.
      source = ScreenshotSource.fromWire(rawSource);
    } on ProtocolFormatException {
      bad('records an unknown "source" of "$rawSource". Known: '
          '${ScreenshotSource.values.map((s) => s.wire).join(', ')}.');
    }

    final rawRecordedAt = json['recordedAt'];
    if (rawRecordedAt == null) bad('records no "recordedAt".');
    final recordedAt =
        rawRecordedAt is String ? DateTime.tryParse(rawRecordedAt) : null;
    if (recordedAt == null) {
      bad('records "recordedAt" as "$rawRecordedAt", which is not a '
          'timestamp, as in "2026-09-12T18:23:48.614060Z".');
    }

    // Optional, and absent still means absent: baselines committed
    // before this was written down do not record one, and reading it
    // strictly would turn every one of them into a failure.
    final rawRatio = json['devicePixelRatio'];
    if (rawRatio != null && rawRatio is! num) {
      bad('records "devicePixelRatio" as "$rawRatio", which is not a '
          'number.');
    }

    // No unknown-key check, deliberately. A reader that did not know
    // about a key must not choke on it - the same forward compatibility
    // `write` relies on when it adds the environment block.
    return Baseline(
      bytes: bytes,
      source: source,
      width: pixels('width'),
      height: pixels('height'),
      recordedAt: recordedAt.toUtc(),
      devicePixelRatio: (rawRatio as num?)?.toDouble(),
    );
  }

  Future<void> write(String screenId, Baseline baseline) async {
    final image = imageFile(screenId);
    await image.parent.create(recursive: true);
    await image.writeAsBytes(baseline.bytes);
    await metadataFile(screenId).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
            'screen': screenId,
            if (variant != null) 'fixture': variant,
            ...baseline.metadata,
            ...environment.toJson(),
          })}\n',
    );
  }
}
