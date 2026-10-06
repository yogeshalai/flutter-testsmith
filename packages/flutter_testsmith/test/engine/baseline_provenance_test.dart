import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/protocol.dart';

/// What a baseline says about where it came from.
///
/// A baseline is a picture that somebody accepted, and six months later
/// the only question anyone asks about a failing one is "what was this
/// recorded against?". Until now the file answered with a capture
/// source, a size and a timestamp - enough to refuse an incompatible
/// comparison, not enough to reproduce the recording.
///
/// Recorded, not enforced. Size mismatch already refuses a comparison
/// across two geometries; making the device serial a precondition would
/// mean a baseline could only ever be checked on the machine that took
/// it, which is the opposite of what a committed baseline is for.

Uint8List get png => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, //
      0, 0, 2, 208, // width 720
      0, 0, 6, 64, // height 1600
      8, 2, 0, 0, 0,
    ]);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('baseline_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, Object?> metadataOf(BaselineStore store, String screen) =>
      (jsonDecode(store.metadataFile(screen).readAsStringSync()) as Map)
          .cast<String, Object?>();

  test('records the device, the OS, the app build and the fixture', () async {
    final store = BaselineStore(
      temp,
      variant: 'dashboard_populated',
      environment: const BaselineEnvironment(
        device: 'RZ8T11QETWM',
        deviceModel: 'SM-M127G',
        osVersion: 'Android 13 (API 33)',
        appVersion: '1.0.6',
        buildMode: 'debug',
        devicePixelRatio: 1.875,
      ),
    );

    await store.write(
      '/home',
      Baseline(
        bytes: png,
        source: ScreenshotSource.deviceScreencap,
        width: 720,
        height: 1600,
        recordedAt: DateTime.utc(2026, 9, 12),
      ),
    );

    final json = metadataOf(store, '/home');

    expect(json['screen'], '/home');
    expect(json['fixture'], 'dashboard_populated');
    expect(json['source'], 'deviceScreencap');
    expect(json['width'], 720);
    expect(json['height'], 1600);
    expect(json['device'], 'RZ8T11QETWM');
    expect(json['deviceModel'], 'SM-M127G');
    expect(json['osVersion'], 'Android 13 (API 33)');
    expect(json['appVersion'], '1.0.6');
    expect(json['buildMode'], 'debug');
    expect(json['devicePixelRatio'], 1.875);
  });

  test('a store with no environment writes exactly what it wrote before',
      () async {
    // Every baseline recorded before this existed must still read, and
    // re-recording one on a runner that cannot name the device must not
    // invent a value for it.
    final store = BaselineStore(temp);

    await store.write(
      '/profile',
      Baseline(
        bytes: png,
        source: ScreenshotSource.deviceScreencap,
        width: 720,
        height: 1600,
        recordedAt: DateTime.utc(2026, 9, 12),
      ),
    );

    expect(
      metadataOf(store, '/profile').keys,
      ['screen', 'source', 'width', 'height', 'recordedAt'],
    );
  });

  test('reads back a baseline whose metadata carries provenance', () async {
    // Forward compatibility in the direction that matters: a reader that
    // did not know about these keys must not choke on them.
    final store = BaselineStore(
      temp,
      environment: const BaselineEnvironment(device: 'RZ8T11QETWM'),
    );

    await store.write(
      '/home',
      Baseline(
        bytes: png,
        source: ScreenshotSource.deviceScreencap,
        width: 720,
        height: 1600,
        recordedAt: DateTime.utc(2026, 9, 12),
      ),
    );

    final read = await store.read('/home');

    expect(read, isNotNull);
    expect(read!.width, 720);
    expect(read.source, ScreenshotSource.deviceScreencap);
  });

  test('leaves out what it was not told', () async {
    final store = BaselineStore(
      temp,
      environment: const BaselineEnvironment(device: 'emulator-5554'),
    );

    await store.write(
      '/home',
      Baseline(
        bytes: png,
        source: ScreenshotSource.deviceScreencap,
        width: 720,
        height: 1600,
        recordedAt: DateTime.utc(2026, 9, 12),
      ),
    );

    final json = metadataOf(store, '/home');

    expect(json['device'], 'emulator-5554');
    expect(json.containsKey('osVersion'), isFalse);
    expect(json.containsKey('appVersion'), isFalse);
  });
}
