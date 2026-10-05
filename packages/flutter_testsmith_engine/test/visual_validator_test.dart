import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

Uint8List _png(int width, int height, {int colour = 0xFFFFFF}) {
  final image = img.Image(width: width, height: height);
  img.fill(
    image,
    color: img.ColorRgb8(
      (colour >> 16) & 0xFF,
      (colour >> 8) & 0xFF,
      colour & 0xFF,
    ),
  );
  return Uint8List.fromList(img.encodePng(image));
}

UiSnapshot _snapshot({
  double ratio = 2.0,
  List<UiNode> children = const [],
}) =>
    UiSnapshot(
      screenId: '/product/details',
      capturedAt: DateTime.utc(2026),
      devicePixelRatio: ratio,
      viewport: const LogicalRect(x: 0, y: 0, width: 100, height: 100),
      root: UiNode(
        type: 'Root',
        bounds: const LogicalRect(x: 0, y: 0, width: 100, height: 100),
        children: children,
      ),
    );

void main() {
  coveredRouteTests();
  baselineVariantTests();
  baselineSelectionOnThePathTests();
  late Directory temp;
  late BaselineStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('visual_baselines');
    store = BaselineStore(temp);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  const validator = VisualValidator();

  group('pngDimensions', () {
    test('reads the size from the header', () {
      expect(pngDimensions(_png(320, 240)), (width: 320, height: 240));
    });

    test('returns null for something that is not a PNG', () {
      expect(pngDimensions(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('first run', () {
    test('records a baseline and skips, because a first run cannot '
        'detect a regression', () async {
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(40, 40),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.skip);
      expect(results.single.message, contains('no baseline'));
      expect(store.imageFile('/product/details').existsSync(), isTrue);
    });

    test('records the size and capture path beside the image', () async {
      await validator.validate(
        screenId: '/product/details',
        screenshot: _png(40, 60),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      final baseline = await store.read('/product/details');

      expect(baseline!.width, 40);
      expect(baseline.height, 60);
      expect(baseline.source, ScreenshotSource.deviceScreencap);
    });
  });

  group('against a baseline', () {
    setUp(() async {
      await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );
    });

    test('an identical screenshot passes', () async {
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.pass);
    });

    test('a changed screenshot fails and does not overwrite the '
        'baseline', () async {
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64, colour: 0x000000),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.fail);

      // The baseline must survive a failure: a store that re-records on
      // difference is a suite that can never fail the same way twice.
      final baseline = await store.read('/product/details');
      final again = await const VisualComparator().compare(
        baseline: baseline!.bytes,
        current: _png(64, 64),
      );
      expect(again.passed, isTrue);
    });

    test('replaces the baseline only when asked', () async {
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64, colour: 0x000000),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        updateBaseline: true,
      );

      expect(results.single.status, ValidationStatus.skip);
      expect(results.single.message, contains('replaced'));

      final baseline = await store.read('/product/details');
      expect(pngDimensions(baseline!.bytes), (width: 64, height: 64));
    });

    test('refuses to compare across capture paths', () async {
      // A RepaintBoundary image has no status bar; a screencap does.
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.repaintBoundary,
        store: store,
      );

      expect(results.single.status, ValidationStatus.error);
      expect(results.single.message, contains('repaintBoundary'));
      expect(results.single.message, contains('deviceScreencap'));
    });

    test('a resized screenshot is an error about size, not a pixel '
        'count', () async {
      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 80),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.fail);
      expect(results.single.message, contains('different sizes'));
    });
  });

  group('regions', () {
    test('an ignored element hides its own change', () async {
      // A 20x20 logical element at 2x is 40x40 image pixels.
      final snapshot = _snapshot(
        children: [
          const UiNode(
            testId: 'product.clock',
            type: 'Text',
            text: '09:41',
            bounds: LogicalRect(x: 0, y: 0, width: 32, height: 32),
          ),
        ],
      );

      const config = VisualCheckConfig(ignoreElements: ['product.clock']);

      await validator.validate(
        screenId: '/home',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: snapshot,
        config: config,
      );

      // Repaint the whole top-left 64x64 area, which the element covers.
      final changed = img.Image(width: 64, height: 64);
      img.fill(changed, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(
        changed,
        x1: 0,
        y1: 0,
        x2: 63,
        y2: 63,
        color: img.ColorRgb8(0, 0, 0),
      );

      final results = await validator.validate(
        screenId: '/home',
        screenshot: Uint8List.fromList(img.encodePng(changed)),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: snapshot,
        config: config,
      );

      expect(results.single.status, ValidationStatus.pass);
    });

    test('names the element that changed', () async {
      final snapshot = _snapshot(
        children: [
          const UiNode(
            testId: 'product.price',
            type: 'Text',
            text: 'Rs 90',
            bounds: LogicalRect(x: 0, y: 0, width: 16, height: 16),
          ),
        ],
      );

      await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: snapshot,
        updateBaseline: true,
      );

      final changed = img.Image(width: 64, height: 64);
      img.fill(changed, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(
        changed,
        x1: 0,
        y1: 0,
        x2: 31,
        y2: 31,
        color: img.ColorRgb8(0, 0, 0),
      );

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: Uint8List.fromList(img.encodePng(changed)),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: snapshot,
      );

      expect(results.single.status, ValidationStatus.fail);
      expect(results.single.message, contains('product.price'));
    });
  });
}

/// Phase 12: a screen does not look the same under every API state, and
/// that is not a regression.
void baselineVariantTests() {
  group('baseline variants', () {
    test('the default state keeps the plain file name', () {
      // Every baseline recorded before variants existed must still
      // resolve, or this change silently invalidates the repository.
      expect(BaselineStore.fileNameFor('/product/details'),
          'product_details');
      expect(BaselineStore.fileNameFor('/product/details', null),
          'product_details');
    });

    test('a named fixture gets its own file', () {
      expect(
        BaselineStore.fileNameFor('/product/details', 'product_out_of_stock'),
        'product_details@product_out_of_stock',
      );
    });

    test('a store with a variant looks at a different file', () {
      final directory = Directory('build/does-not-exist');
      final plain = BaselineStore(directory);
      final variant = BaselineStore(directory, variant: 'api_500_server_error');

      expect(
        plain.imageFile('/product/details').path,
        isNot(variant.imageFile('/product/details').path),
      );
      expect(
        variant.imageFile('/product/details').path,
        contains('@api_500_server_error'),
      );
    });

    test('a variant name is made filesystem-safe too', () {
      expect(
        BaselineStore.fileNameFor('/s', 'weird/name with spaces'),
        's@weird_name_with_spaces',
      );
    });
  });
}

/// D-12, engine side: an element belonging to a covered route must not
/// be measured. The SDK's own test proves the index is recorded; this
/// proves the validator acts on it.
void coveredRouteTests() {
  UiNode leaf(String id, {int? routeIndex, double y = 10}) => UiNode(
        testId: id,
        type: 'Text',
        bounds: LogicalRect(x: 0, y: y, width: 50, height: 20),
        properties: {'routeIndex': ?routeIndex},
      );

  UiSnapshot treeOf(List<UiNode> children) => UiSnapshot(
        screenId: '/top',
        capturedAt: DateTime.utc(2026),
        devicePixelRatio: 2,
        viewport: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
        root: UiNode(
          type: 'Root',
          bounds: const LogicalRect(x: 0, y: 0, width: 400, height: 800),
          children: children,
        ),
      );

  /// The labels the validator would measure, read back from the
  /// comparison it performs.
  Future<Set<String>> measured(UiSnapshot snapshot) async {
    final directory = Directory.systemTemp.createTempSync('d12');
    addTearDown(() => directory.deleteSync(recursive: true));

    final store = BaselineStore(directory);
    final image = _png(64, 64);

    // Record, then compare against an identical image: nothing differs,
    // but every measured region is reported.
    await const VisualValidator().validate(
      screenId: '/top',
      screenshot: image,
      source: ScreenshotSource.deviceScreencap,
      store: store,
      snapshot: snapshot,
    );

    final captured = <String>{};
    final comparator = _RecordingComparator(captured);
    await VisualValidator(comparator: comparator).validate(
      screenId: '/top',
      screenshot: image,
      source: ScreenshotSource.deviceScreencap,
      store: store,
      snapshot: snapshot,
    );
    return captured;
  }

  group('covered routes', () {
    test('an element on a lower route is not measured', () async {
      final labels = await measured(
        treeOf([
          leaf('under.label', routeIndex: 1),
          leaf('over.label', routeIndex: 2, y: 40),
        ]),
      );

      expect(labels, contains('over.label'));
      expect(labels, isNot(contains('under.label')));
    });

    test('two elements on the same route are both measured', () async {
      final labels = await measured(
        treeOf([
          leaf('a', routeIndex: 2),
          leaf('b', routeIndex: 2, y: 40),
        ]),
      );

      expect(labels, containsAll(<String>['a', 'b']));
    });

    test('a tree with no route indices measures everything', () async {
      // The graceful fallback for an older SDK.
      final labels = await measured(treeOf([leaf('a'), leaf('b', y: 40)]));

      expect(labels, containsAll(<String>['a', 'b']));
    });

    test('an element outside any route is kept', () async {
      // App-level chrome above the navigator is genuinely on screen.
      final labels = await measured(
        treeOf([leaf('chrome'), leaf('over.label', routeIndex: 3, y: 40)]),
      );

      expect(labels, containsAll(<String>['chrome', 'over.label']));
    });
  });
}

/// Records which regions it was asked to compare.
class _RecordingComparator extends VisualComparator {
  const _RecordingComparator(this.seen);

  final Set<String> seen;

  @override
  Future<VisualComparison> compare({
    required Uint8List baseline,
    required Uint8List current,
    List<PixelRegion> ignore = const [],
    List<PixelRegion> regions = const [],
  }) async {
    for (final region in regions) {
      seen.add(region.label);
    }
    return const VisualComparison(
      overall: RegionComparison(
        label: 'screen',
        differingPixels: 0,
        totalPixels: 1,
        maxChannelDelta: 0,
        ssim: 1,
      ),
      passed: true,
      summary: 'recorded',
    );
  }
}

/// What the run may compare against, and saying so out loud.
///
/// The store can already answer this - [BaselineStore.select] returns
/// exactly one candidate, or refuses with the reason. These tests exist
/// because answering it in a library nobody calls is the same as not
/// answering it: a validator that reads the first file it finds will
/// happily compare against a picture taken on another device, and
/// report a clean pass that means nothing.
void baselineSelectionOnThePathTests() {
  late Directory temp;
  const validator = VisualValidator();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('baseline_selection_path');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// Writes a baseline directly, so a test can set up conditions a
  /// first run would never produce - two candidates, or one recorded on
  /// different hardware.
  Future<void> put(
    String path, {
    int width = 64,
    int height = 64,
    double? ratio,
    String model = 'SM-M127G',
  }) async {
    await File('$path.png').writeAsBytes(_png(width, height));
    await File('$path.json').writeAsString(jsonEncode({
      'screen': '/product/details',
      'source': 'deviceScreencap',
      'width': width,
      'height': height,
      'recordedAt': '2026-09-12T00:00:00.000Z',
      'deviceModel': model,
      'devicePixelRatio': ?ratio,
    }));
  }

  /// The same, with metadata this file did not build.
  ///
  /// [put] writes it with `jsonEncode`, so every test above reaches the
  /// reader through a document that is well formed by construction.
  Future<void> putRaw(String path, String metadata) async {
    await File('$path.png').writeAsBytes(_png(64, 64));
    await File('$path.json').writeAsString(metadata);
  }

  final profile = DeviceProfile.parse('''
id: samsung-m127g
model: SM-M127G
os: Android 13
physical: {width: 64, height: 64}
devicePixelRatio: 1.875
''', source: 'test');

  group('the selection is on the execution path', () {
    test('two candidates is an ERROR naming both, not a silent pick',
        () async {
      final store = BaselineStore(temp, profile: profile);
      final paths = store.candidatePaths('/product/details');
      expect(paths.length, greaterThan(1),
          reason: 'this test needs a layout with more than one candidate');
      for (final path in paths) {
        await Directory(File('$path.png').parent.path)
            .create(recursive: true);
        await put(path, ratio: 1.875);
      }

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.error);
      for (final path in paths) {
        expect(results.single.message, contains(path));
      }
    });

    test('a baseline from other hardware is an ERROR, not a comparison',
        () async {
      final store = BaselineStore(temp, profile: profile);
      final path = store.candidatePaths('/product/details').first;
      await Directory(File('$path.png').parent.path).create(recursive: true);
      // Recorded at a different pixel ratio: the arithmetic of the
      // comparison would be wrong, so it must not happen at all.
      await put(path, ratio: 3.0);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(results.single.status, ValidationStatus.error);
      expect(results.single.message, contains('3.0'));
      expect(results.single.message, contains('1.875'));
    });

    test('a missing baseline names where it looked', () async {
      final store = BaselineStore(temp, profile: profile);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      // Still recorded, as before - but it says what it searched.
      expect(results.single.status, ValidationStatus.skip);
      expect(results.single.message, contains('no baseline'));
    });
  });

  /// A baseline whose metadata cannot be read is the store refusing, and
  /// `_compare` already says what that means here: `on StateError` ->
  /// an ERROR carrying the reason, the same outcome two candidates and
  /// incompatible hardware get.
  ///
  /// Only the absent metadata file arrived as a `StateError`. Measured
  /// against 9428a0f, each document below left `BaselineStore.select` as
  /// a `_TypeError`, a `FormatException` or a `ProtocolFormatException`,
  /// walked past that guard, and left the validator entirely - so a
  /// committed file somebody mis-merged became an exception thrown from
  /// the middle of a run rather than a finding about a screen.
  group('metadata the store cannot read', () {
    Future<ValidationResult> validating(String metadata) async {
      final store = BaselineStore(temp, profile: profile);
      final path = store.candidatePaths('/product/details').first;
      await Directory(File('$path.png').parent.path).create(recursive: true);
      await putRaw(path, metadata);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );
      return results.single;
    }

    test('a mistyped field is an ERROR, not an exception out of the run',
        () async {
      final result = await validating(
        '{"source": "deviceScreencap", "width": "wide", "height": 64, '
        '"recordedAt": "2026-09-12T00:00:00.000Z"}',
      );

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('"width"'));
      expect(result.message, contains('.json'));
    });

    test('an unreadable timestamp is an ERROR', () async {
      final result = await validating(
        '{"source": "deviceScreencap", "width": 64, "height": 64, '
        '"recordedAt": "yesterday"}',
      );

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('"recordedAt"'));
    });

    test('a capture source nothing records is an ERROR', () async {
      final result = await validating(
        '{"source": "webcam", "width": 64, "height": 64, '
        '"recordedAt": "2026-09-12T00:00:00.000Z"}',
      );

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('"source"'));
    });

    test('a file somebody merged badly is an ERROR', () async {
      final result = await validating(
        '<<<<<<< HEAD\n{"screen": "/product/details"}\n=======\n'
        '{"screen": "/product/details"}\n>>>>>>> theirs\n',
      );

      expect(result.status, ValidationStatus.error);
      expect(result.message, contains('.json'));
    });

    test('the dimension is still visual, so the report files it with the '
        'other two refusals', () async {
      final result = await validating(
        '{"source": "deviceScreencap", "width": "wide", "height": 64, '
        '"recordedAt": "2026-09-12T00:00:00.000Z"}',
      );

      expect(result.dimension, ValidationDimension.visual);
      expect(result.validatorId, VisualValidator.id);
    });

    test('and the baseline is not re-recorded over on the way out',
        () async {
      // The invariant this store exists for: nothing accepts a new
      // image on its own. A refusal that replaced the file would make
      // the next run pass for the wrong reason.
      final store = BaselineStore(temp, profile: profile);
      final path = store.candidatePaths('/product/details').first;
      await Directory(File('$path.png').parent.path).create(recursive: true);
      const broken = '{"source": "deviceScreencap", "width": "wide", '
          '"height": 64, "recordedAt": "2026-09-12T00:00:00.000Z"}';
      await putRaw(path, broken);

      await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64, colour: 0x000000),
        source: ScreenshotSource.deviceScreencap,
        store: store,
      );

      expect(await File('$path.json').readAsString(), broken);
    });

    test('a well formed one still passes, so nothing else moved', () async {
      final result = await validating(
        '{"source": "deviceScreencap", "width": 64, "height": 64, '
        '"recordedAt": "2026-09-12T00:00:00.000Z", '
        '"devicePixelRatio": 1.875}',
      );

      expect(result.status, ValidationStatus.pass);
    });
  });

  group('the selection is recorded', () {
    test('a passing comparison records which baseline it compared against',
        () async {
      final store = BaselineStore(temp, profile: profile);
      final path = store.candidatePaths('/product/details').first;
      await Directory(File('$path.png').parent.path).create(recursive: true);
      await put(path, ratio: 1.875);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: _snapshot(ratio: 1.875),
      );

      expect(results.single.status, ValidationStatus.pass);

      // A pass that does not say what it compared against is not
      // evidence of anything. The path, the profile it was checked
      // against, the resolution, the pixel ratio, and the fact that
      // compatibility was asserted rather than assumed.
      final kinds = {
        for (final e in results.single.evidence) e.kind: e.reference,
      };
      expect(kinds['baseline'], path);
      expect(kinds['deviceProfile'], 'samsung-m127g');
      expect(kinds['resolution'], '64x64');
      expect(kinds['devicePixelRatio'], '1.875');
      expect(kinds['compatibility'], 'compatible');
    });

    test('a failing comparison records it too', () async {
      final store = BaselineStore(temp, profile: profile);
      final path = store.candidatePaths('/product/details').first;
      await Directory(File('$path.png').parent.path).create(recursive: true);
      await put(path, ratio: 1.875);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64, colour: 0x000000),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: _snapshot(ratio: 1.875),
      );

      expect(results.single.status, ValidationStatus.fail);
      final kinds = {
        for (final e in results.single.evidence) e.kind: e.reference,
      };
      expect(kinds['baseline'], path);
      expect(kinds['compatibility'], 'compatible');
    });

    test('a legacy flat baseline is reported as one while still counting',
        () async {
      final store = BaselineStore(temp, profile: profile);
      final legacy = store.candidatePaths('/product/details').last;
      await Directory(File('$legacy.png').parent.path).create(recursive: true);
      await put(legacy, ratio: 1.875);

      final results = await validator.validate(
        screenId: '/product/details',
        screenshot: _png(64, 64),
        source: ScreenshotSource.deviceScreencap,
        store: store,
        snapshot: _snapshot(ratio: 1.875),
      );

      expect(results.single.status, ValidationStatus.pass);
      final kinds = {
        for (final e in results.single.evidence) e.kind: e.reference,
      };
      expect(kinds['baseline'], legacy);
      expect(kinds['baselineLayout'], 'legacy');
    });
  });
}
