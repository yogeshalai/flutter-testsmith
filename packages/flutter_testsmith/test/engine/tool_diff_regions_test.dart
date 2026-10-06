import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A tool, not a check: says *where* two PNGs differ.
///
/// Run it when a visual comparison reports a constant, unexplained
/// difference. "0.065% of the screen differs on every run" is a number;
/// "rows 1460-1509 differ" is a diagnosis.
///
///   dart test test/tool_diff_regions_test.dart --plain-name locate
void main() {
  test('locate', () {
    const baseline =
        '../../examples/ecommerce_app/visual_baselines/product_details.png';
    const current = '../../out/repeat/product-details.png';

    if (!File(baseline).existsSync() || !File(current).existsSync()) {
      // A tool that needs a device run behind it. Skipped, not failed,
      // when there is nothing to look at.
      markTestSkipped('needs a device run: $baseline and $current');
      return;
    }

    final a = img.decodePng(File(baseline).readAsBytesSync())!;
    final b = img.decodePng(File(current).readAsBytesSync())!;
    expect(a.width, b.width);
    expect(a.height, b.height);

    const channelDelta = 8;
    final perRow = List<int>.filled(a.height, 0);
    var total = 0;
    var minX = a.width;
    var maxX = 0;

    for (var y = 0; y < a.height; y++) {
      for (var x = 0; x < a.width; x++) {
        final p = a.getPixel(x, y);
        final q = b.getPixel(x, y);
        final delta = [
          (p.r - q.r).abs(),
          (p.g - q.g).abs(),
          (p.b - q.b).abs(),
          (p.a - q.a).abs(),
        ].reduce((m, n) => m > n ? m : n);
        if (delta > channelDelta) {
          perRow[y]++;
          total++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
    }

    // Contiguous bands of rows that contain any difference.
    final bands = <(int, int, int)>[];
    var start = -1;
    var count = 0;
    for (var y = 0; y <= a.height; y++) {
      final has = y < a.height && perRow[y] > 0;
      if (has && start == -1) {
        start = y;
        count = 0;
      }
      if (has) count += perRow[y];
      if (!has && start != -1) {
        bands.add((start, y - 1, count));
        start = -1;
      }
    }

    // ignore: avoid_print
    print('image ${a.width}x${a.height}, $total differing pixels '
        '(${(total / (a.width * a.height) * 100).toStringAsFixed(3)}%), '
        'x from $minX to $maxX');
    for (final (from, to, pixels) in bands) {
      // ignore: avoid_print
      print('  rows $from-$to: $pixels pixels');
    }
  });
}
