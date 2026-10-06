import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

/// Choosing which recorded picture a run is allowed to compare against.
///
/// The old store answered this with a filename and nothing else: one
/// path, read it if it is there. That is deterministic, but it cannot
/// say *no* - a baseline recorded on a 1080x2400 phone resolved happily
/// on a 720x1600 one, and the comparison then reported a screen that had
/// not changed as different everywhere.
///
/// Selection now has four outcomes and never a fifth. There is no
/// "closest match", because the closest match to a picture of a
/// different device is still a picture of a different device.
final _profile = DeviceProfile.parse('''
id: samsung-m127g
model: SM-M127G
physical:
  width: 720
  height: 1600
devicePixelRatio: 1.875
''', source: 'test');

/// A 1x1 PNG. The bytes matter only in that `pngDimensions` can read
/// them; nothing here compares pixels.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
]);

Directory _temp() {
  final directory = Directory.systemTemp.createTempSync('baselines');
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

/// Writes a baseline at [relative], with whatever metadata is given.
void _write(
  Directory root,
  String relative, {
  int width = 720,
  int height = 1600,
  double ratio = 1.875,
}) {
  final image = File('${root.path}/$relative.png')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(_png);
  File('${root.path}/$relative.json').writeAsStringSync(jsonEncode({
    'screen': '/home',
    'source': ScreenshotSource.deviceScreencap.wire,
    'width': width,
    'height': height,
    'recordedAt': '2026-09-12T18:23:48.614060Z',
    'deviceModel': 'SM-M127G',
    'devicePixelRatio': ratio,
  }));
  expect(image.existsSync(), isTrue);
}

/// Writes a baseline whose metadata is exactly [metadata].
///
/// [_write] builds the file with `jsonEncode`, so it can only ever
/// produce a well formed one - and every test here reached the reader
/// through it. A committed `visual_baselines/*.json` is edited, merged
/// and reviewed like any other file, and this is the only way to hand
/// the reader one it did not write itself.
void _writeRaw(Directory root, String relative, String metadata) {
  File('${root.path}/$relative.png')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(_png);
  File('${root.path}/$relative.json').writeAsStringSync(metadata);
}

BaselineStore _store(Directory root) =>
    BaselineStore(root, profile: _profile);

void main() {
  group('a baseline filed under the profile', () {
    test('is selected', () async {
      final root = _temp();
      _write(root, 'samsung-m127g/home');

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineSelected>());
      expect((selection as BaselineSelected).path, contains('samsung-m127g'));
    });
  });

  group('a legacy baseline beside the directory', () {
    test('still resolves, so committed baselines keep working', () async {
      // Every baseline recorded before profiles existed sits flat in
      // visual_baselines/. Refusing those would have made this change a
      // migration rather than an addition.
      final root = _temp();
      _write(root, 'home');

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineSelected>());
      expect((selection as BaselineSelected).isLegacyPath, isTrue);
    });
  });

  group('both present', () {
    test('is ambiguous, and names both', () async {
      // A half-finished migration. Picking either one would be a guess,
      // and the two pictures are not the same picture.
      final root = _temp();
      _write(root, 'home');
      _write(root, 'samsung-m127g/home');

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineAmbiguous>());
      final paths = (selection as BaselineAmbiguous).paths;
      expect(paths, hasLength(2));
      expect(paths.join(' '), contains('samsung-m127g'));
    });

    test('does not quietly prefer the more specific one', () async {
      final root = _temp();
      _write(root, 'home');
      _write(root, 'samsung-m127g/home');

      expect(await _store(root).select('/home'), isNot(isA<BaselineSelected>()));
    });
  });

  group('nothing present', () {
    test('is missing, and says where it looked', () async {
      final root = _temp();

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineMissing>());
      expect((selection as BaselineMissing).searched, hasLength(2));
    });
  });

  group('present but recorded elsewhere', () {
    test('a different resolution is incompatible, not a difference', () async {
      // This is the case the old store got wrong. A baseline recorded at
      // 1080x2400 against a 720x1600 device differs in every pixel, and
      // reporting that as a visual regression is true and useless.
      final root = _temp();
      _write(root, 'samsung-m127g/home', width: 1080, height: 2400);

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineIncompatible>());
      expect(
        (selection as BaselineIncompatible).reasons.join(' '),
        contains('1080x2400'),
      );
    });

    test('a different pixel ratio is incompatible', () async {
      final root = _temp();
      _write(root, 'samsung-m127g/home', ratio: 3);

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineIncompatible>());
      expect(
        (selection as BaselineIncompatible).reasons.join(' '),
        contains('3'),
      );
    });

    test('a legacy baseline is checked just as strictly', () async {
      // Being old is not a reason to be trusted.
      final root = _temp();
      _write(root, 'home', width: 1080, height: 2400);

      expect(await _store(root).select('/home'), isA<BaselineIncompatible>());
    });
  });

  group('with no profile configured', () {
    test('falls back to the legacy path and compares nothing', () async {
      // `testsmith run` without a suite has no profile. It behaves exactly
      // as it did before profiles existed.
      final root = _temp();
      _write(root, 'home', width: 1080, height: 2400);

      final selection = await BaselineStore(root).select('/home');

      expect(selection, isA<BaselineSelected>());
    });
  });

  group('variants', () {
    test('are part of the name, under the profile too', () async {
      final root = _temp();
      _write(root, 'samsung-m127g/home@dashboard_populated');

      final selection =
          await BaselineStore(root, profile: _profile, variant: 'dashboard_populated')
              .select('/home');

      expect(selection, isA<BaselineSelected>());
    });

    test('do not resolve across fixtures', () async {
      final root = _temp();
      _write(root, 'samsung-m127g/home@dashboard_populated');

      final selection =
          await BaselineStore(root, profile: _profile, variant: 'orders_populated')
              .select('/home');

      expect(selection, isA<BaselineMissing>());
    });
  });

  /// A metadata file that is there and wrong, as distinct from the one
  /// that is not there at all.
  ///
  /// The absent file has always been a [StateError], which is the type
  /// `VisualValidator` catches to report a visual ERROR. The fields
  /// inside it were read with `!` and `as`, so a file that was valid
  /// JSON and wrong left the reader as a `_TypeError` - and one that was
  /// not JSON at all as a bare `FormatException` - neither of which is a
  /// `StateError`, so neither reached that guard. Measured against
  /// 9428a0f on every case below.
  ///
  /// The same defect `c9c4532` removed from figma specs, on the other
  /// committed JSON artefact.
  group('metadata that cannot be read', () {
    Future<StateError> refusal(String metadata) async {
      final root = _temp();
      _writeRaw(root, 'samsung-m127g/home', metadata);

      try {
        await _store(root).select('/home');
      } on StateError catch (error) {
        return error;
      }
      fail('this metadata was expected to be refused: $metadata');
    }

    /// Names the file, names the field, and says what to do about it -
    /// which is what the absent-file refusal has always done.
    void expectUsable(StateError error, {String? field}) {
      expect(error.message, contains('home.json'));
      if (field != null) expect(error.message, contains('"$field"'));
      expect(error.message, contains('re-record'));
    }

    test('a "width" that is a word', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "width": "wide", '
            '"height": 1600, "recordedAt": "2026-09-12T18:23:48.614060Z"}'),
        field: 'width',
      );
    });

    test('a "width" that is not there', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "height": 1600, '
            '"recordedAt": "2026-09-12T18:23:48.614060Z"}'),
        field: 'width',
      );
    });

    test('a "height" that is not there, checked the same way', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "width": 720, '
            '"recordedAt": "2026-09-12T18:23:48.614060Z"}'),
        field: 'height',
      );
    });

    test('a "source" that is not there', () async {
      expectUsable(
        await refusal('{"width": 720, "height": 1600, '
            '"recordedAt": "2026-09-12T18:23:48.614060Z"}'),
        field: 'source',
      );
    });

    test('a "source" nothing was ever captured through', () async {
      final error = await refusal('{"source": "webcam", "width": 720, '
          '"height": 1600, "recordedAt": "2026-09-12T18:23:48.614060Z"}');

      expectUsable(error, field: 'source');
      // The two that exist, because a reader who wrote the wrong one
      // needs to know what the right ones are.
      expect(error.message, contains('deviceScreencap'));
      expect(error.message, contains('repaintBoundary'));
    });

    test('a "recordedAt" that is not a timestamp', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "width": 720, '
            '"height": 1600, "recordedAt": "yesterday"}'),
        field: 'recordedAt',
      );
    });

    test('a "recordedAt" that is not there', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "width": 720, '
            '"height": 1600}'),
        field: 'recordedAt',
      );
    });

    test('a "devicePixelRatio" that is a word', () async {
      expectUsable(
        await refusal('{"source": "deviceScreencap", "width": 720, '
            '"height": 1600, "recordedAt": "2026-09-12T18:23:48.614060Z", '
            '"devicePixelRatio": "2x"}'),
        field: 'devicePixelRatio',
      );
    });

    test('a document that is a list rather than an object', () async {
      expectUsable(await refusal('[1, 2, 3]'));
    });

    test('a file somebody merged badly', () async {
      // The most likely way this file is ever wrong: two people
      // re-recorded the same screen.
      expectUsable(await refusal(
        '<<<<<<< HEAD\n{"screen": "/home"}\n=======\n'
        '{"screen": "/home"}\n>>>>>>> theirs\n',
      ));
    });

    test('a file with nothing in it', () async {
      expectUsable(await refusal(''));
    });
  });

  group('and what a bad metadata file must not change', () {
    test('a well formed one still selects', () async {
      final root = _temp();
      _writeRaw(
        root,
        'samsung-m127g/home',
        '{"screen": "/home", "source": "deviceScreencap", "width": 720, '
            '"height": 1600, "recordedAt": "2026-09-12T18:23:48.614060Z", '
            '"devicePixelRatio": 1.875}',
      );

      expect(await _store(root).select('/home'), isA<BaselineSelected>());
    });

    test('an absent "devicePixelRatio" is still no ratio, not a refusal',
        () async {
      // Both baselines committed to this repository omit it. Reading it
      // strictly would have turned them into failures.
      final root = _temp();
      _writeRaw(
        root,
        'samsung-m127g/home',
        '{"source": "deviceScreencap", "width": 720, "height": 1600, '
            '"recordedAt": "2026-09-12T18:23:48.614060Z"}',
      );

      final selection = await _store(root).select('/home');

      expect(selection, isA<BaselineSelected>());
      expect((selection as BaselineSelected).baseline.devicePixelRatio, isNull);
    });

    test('a key the reader does not know is still ignored', () async {
      // Forward compatibility in the direction that matters, as
      // baseline_provenance_test puts it: a reader that did not know
      // about a key must not choke on it.
      final root = _temp();
      _writeRaw(
        root,
        'samsung-m127g/home',
        '{"source": "deviceScreencap", "width": 720, "height": 1600, '
            '"recordedAt": "2026-09-12T18:23:48.614060Z", '
            '"somethingAddedLater": {"a": 1}}',
      );

      expect(await _store(root).select('/home'), isA<BaselineSelected>());
    });

    test('metadata that is not there at all is refused as it always was',
        () async {
      final root = _temp();
      File('${root.path}/samsung-m127g/home.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(_png);

      await expectLater(
        _store(root).select('/home'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('has no'),
              contains('how it was captured is unknown'),
              contains('Delete it and re-record.'),
            ),
          ),
        ),
      );
    });
  });
}
