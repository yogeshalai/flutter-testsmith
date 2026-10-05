import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

LogicalRect _rect(double x, double y, double w, double h) =>
    LogicalRect(x: x, y: y, width: w, height: h);

void main() {
  group('DesignProjection', () {
    test('scales by the width ratio, because designs are authored to a '
        'width', () {
      final projection = DesignProjection.fitWidth(
        designWidth: 402,
        designHeight: 874,
        screenWidth: 804,
        screenHeight: 1748,
      );

      expect(projection.scale, 2.0);
    });

    test('is the identity when the design and screen widths agree', () {
      final projection = DesignProjection.fitWidth(
        designWidth: 400,
        designHeight: 800,
        screenWidth: 400,
        screenHeight: 800,
      );

      final projected = projection.project(_rect(20, 40, 100, 30));

      expect(projected, _rect(20, 40, 100, 30));
    });

    test('projects a design rect into device logical pixels', () {
      final projection = DesignProjection.fitWidth(
        designWidth: 402,
        designHeight: 874,
        screenWidth: 201,
        screenHeight: 437,
      );

      final projected = projection.project(_rect(20, 100, 362, 48));

      expect(projected.x, 10);
      expect(projected.y, 50);
      expect(projected.width, 181);
      expect(projected.height, 24);
    });

    test('offsets the origin so a design without status bar chrome can be '
        'anchored', () {
      final projection = DesignProjection.fitWidth(
        designWidth: 400,
        designHeight: 800,
        screenWidth: 400,
        screenHeight: 800,
        originDy: 24,
      );

      expect(projection.project(_rect(10, 10, 5, 5)).y, 34);
      expect(projection.project(_rect(10, 10, 5, 5)).x, 10);
    });

    test('treats vertical position as comparable when the aspect ratios '
        'agree', () {
      final projection = DesignProjection.fitWidth(
        designWidth: 402,
        designHeight: 804,
        screenWidth: 402,
        screenHeight: 804,
      );

      expect(projection.aspectDelta, 0);
      expect(projection.verticalComparable(0.05), isTrue);
    });

    test('treats vertical position as not comparable when the design is a '
        'very different shape', () {
      // A 402x1198 design scroll frame against a 402x874 viewport.
      final projection = DesignProjection.fitWidth(
        designWidth: 402,
        designHeight: 1198,
        screenWidth: 402,
        screenHeight: 874,
      );

      expect(projection.aspectDelta, greaterThan(0.05));
      expect(projection.verticalComparable(0.05), isFalse);
    });

    test('rejects a design frame with no width rather than dividing by '
        'zero', () {
      expect(
        () => DesignProjection.fitWidth(
          designWidth: 0,
          designHeight: 100,
          screenWidth: 400,
          screenHeight: 800,
        ),
        throwsArgumentError,
      );
    });
  });
}
