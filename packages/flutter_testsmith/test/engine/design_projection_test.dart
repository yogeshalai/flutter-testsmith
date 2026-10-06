import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith/engine.dart';

/// The projection model, on one axis at a time.
///
/// Every case states **why** the expected transformation is correct. The
/// rule the whole model rests on is one sentence:
///
/// > A design coordinate is not a scalable quantity. It is an inset from
/// > an anchor, and a length is a length.
///
/// `x = 329` in a 402-wide frame does not mean "82% of the way across".
/// It means "20px in from the right", and those are the same number only
/// at the width the design was drawn at. Multiplying it by
/// `viewport/design` produces an error that grows with distance from the
/// origin — which is precisely the drift the real device run showed,
/// 5.6px near the top and 63.6px at the bottom.
///
/// So the projection does not scale coordinates. It asks Figma which
/// edge each element is pinned to, and compares the quantity that anchor
/// holds invariant.

/// One axis of a box: where it starts and how long it is.
AxisSpan span(double start, double size) => AxisSpan(start: start, size: size);

AxisProjection project({
  required FigmaAnchor anchor,
  required FigmaSizing sizing,
  required AxisSpan design,
  required AxisSpan designReference,
  required AxisSpan device,
  required AxisSpan deviceReference,
}) =>
    const AnchorProjection().project(
      layout: FigmaAxisLayout(anchor: anchor, sizing: sizing),
      design: design,
      designReference: designReference,
      device: device,
      deviceReference: deviceReference,
    );

/// The design frame and the device viewport used by most cases: 402 wide
/// against 384, the real pair this milestone measured.
final designFrame = span(0, 402);
final viewport = span(0, 384);

void main() {
  group('1. a viewport the same size as the design frame', () {
    test('changes nothing at all', () {
      // The degenerate case, and the one that proves the model is not
      // quietly transforming something. When the two agree, every
      // expected value is the design's own.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(40, 322),
        designReference: designFrame,
        device: span(40, 322),
        deviceReference: designFrame,
      );

      expect(p.expectedPosition, 40);
      expect(p.actualPosition, 40);
      expect(p.expectedSize, 322);
      expect(p.actualSize, 322);
    });
  });

  group('2. and 4. proportional position and size (Figma SCALE)', () {
    test('scales both, because SCALE is the one case that means scale', () {
      // `constraints: SCALE` is Figma stating outright that the element
      // is a proportion of its parent. It is the only sizing where
      // multiplying by the ratio is what the design asked for.
      //
      // 402 -> 384 is a ratio of 0.95522. An element at x=100 w=200
      // becomes x=95.5 w=191.0.
      final p = project(
        anchor: FigmaAnchor.proportional,
        sizing: FigmaSizing.proportional,
        design: span(100, 200),
        designReference: designFrame,
        device: span(96, 191),
        deviceReference: viewport,
      );

      expect(p.expectedPosition, closeTo(95.52, 0.01));
      expect(p.expectedSize, closeTo(191.04, 0.01));
    });
  });

  group('3. fixed horizontal padding', () {
    test('keeps the inset, because padding is a length', () {
      // A 20px gutter is 20px on a narrower screen. The design's own
      // auto-layout says so: resizing an auto-layout frame in Figma does
      // not rescale its padding.
      //
      // This is the single most common real case, and the one width
      // scaling gets wrong: it would expect 19.1 and report a correct
      // 20px gutter as 0.9px out.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fill,
        design: span(20, 362),
        designReference: designFrame,
        device: span(20, 344),
        deviceReference: viewport,
      );

      expect(p.positionLabel, 'leading inset');
      expect(p.expectedPosition, 20);
      expect(p.actualPosition, 20);
    });

    test('and lets a filling element absorb the difference', () {
      // The gutters hold at 20 on both sides, so the element itself is
      // 384 - 40 = 344. That is what FILL means: the parent's extent
      // less this element's own insets.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fill,
        design: span(20, 362),
        designReference: designFrame,
        device: span(20, 344),
        deviceReference: viewport,
      );

      expect(p.expectedSize, 344);
      expect(p.actualSize, 344);
    });
  });

  group('5. a fixed length', () {
    test('is not scaled, because the designer typed a number', () {
      // A 48px button height is 48px. Scaling it to 45.9 invents a
      // 2.1px failure on an application that did exactly as it was
      // told. Measured on the real Login: all three FIXED lengths in
      // that frame (48, 48, 19) match the running app exactly.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(484, 48),
        designReference: span(0, 874),
        device: span(467, 48),
        deviceReference: span(0, 805),
      );

      expect(p.expectedSize, 48);
      expect(p.actualSize, 48);
    });
  });

  group('6. proportional height', () {
    test('scales, for the same reason case 2 does', () {
      final p = project(
        anchor: FigmaAnchor.proportional,
        sizing: FigmaSizing.proportional,
        design: span(0, 400),
        designReference: span(0, 800),
        device: span(0, 200),
        deviceReference: span(0, 400),
      );

      expect(p.expectedSize, 200);
    });
  });

  group('7. top anchoring', () {
    test('compares the distance from the top', () {
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(60, 100),
        designReference: span(0, 874),
        device: span(60, 100),
        deviceReference: span(0, 805),
      );

      expect(p.positionLabel, 'leading inset');
      expect(p.expectedPosition, 60);
      expect(p.actualPosition, 60);
    });
  });

  group('8. bottom anchoring', () {
    test('compares the distance from the bottom, not from the top', () {
      // Figma's `constraints: BOTTOM`, which the real Login frame uses
      // for its "App developed by" row. A bottom-pinned element's top
      // coordinate necessarily changes when the viewport height does;
      // its *bottom* inset is what the design fixed.
      //
      // Design: 874-tall frame, element at y=839 h=19 -> 16 from the
      // bottom. Device: 805-tall viewport, so a correct implementation
      // puts it at 805-16-19 = 770.
      final p = project(
        anchor: FigmaAnchor.end,
        sizing: FigmaSizing.fixed,
        design: span(839, 19),
        designReference: span(0, 874),
        device: span(770, 19),
        deviceReference: span(0, 805),
      );

      expect(p.positionLabel, 'trailing inset');
      expect(p.expectedPosition, 16);
      expect(p.actualPosition, 16);
    });

    test('catches an element pinned to the wrong edge', () {
      // The same element left at its design y on a shorter viewport:
      // 874-tall thinking on an 805-tall screen.
      final p = project(
        anchor: FigmaAnchor.end,
        sizing: FigmaSizing.fixed,
        design: span(839, 19),
        designReference: span(0, 874),
        device: span(839, 19),
        deviceReference: span(0, 805),
      );

      expect(p.expectedPosition, 16);
      expect(p.actualPosition, -53);
    });
  });

  group('9. centre anchoring', () {
    test('compares the offset from the centre', () {
      // The real Login's policy text: 306 wide, centred. Design centre
      // 402/2 = 201; device centre 384/2 = 192. A correct
      // implementation moves it, and its offset from centre stays 0.
      final p = project(
        anchor: FigmaAnchor.centre,
        sizing: FigmaSizing.fixed,
        design: span(48, 306),
        designReference: designFrame,
        device: span(39, 306),
        deviceReference: viewport,
      );

      expect(p.positionLabel, 'centre offset');
      expect(p.expectedPosition, 0);
      expect(p.actualPosition, 0);
    });

    test('catches an element that is centred in the design but not on '
        'the screen', () {
      final p = project(
        anchor: FigmaAnchor.centre,
        sizing: FigmaSizing.fixed,
        design: span(48, 306),
        designReference: designFrame,
        device: span(20, 306),
        deviceReference: viewport,
      );

      expect(p.expectedPosition, 0);
      expect(p.actualPosition, -19);
    });
  });

  group('10. right anchoring', () {
    test('compares the distance from the right edge', () {
      // The real Login's Skip pill: its parent row is HORIZONTAL
      // auto-layout with primaryAxisAlignItems: MAX and paddingRight 20,
      // so the design pins it 20 from the trailing edge.
      final p = project(
        anchor: FigmaAnchor.end,
        sizing: FigmaSizing.hug,
        design: span(329, 53),
        designReference: designFrame,
        device: span(303, 61),
        deviceReference: viewport,
      );

      expect(p.positionLabel, 'trailing inset');
      expect(p.expectedPosition, 20);
      expect(p.actualPosition, 20);
    });
  });

  group('11. a safe-area inset', () {
    test('shifts the content origin, and the inset is not assumed', () {
      // The design frame includes whatever status-bar area the designer
      // drew; the device reports its own. When both are known, the
      // comparison happens in content space - measured from below the
      // inset on each side - so a correct implementation agrees.
      //
      // Design declares 44 of status area and puts the element 16 below
      // it, at y=60. The device's inset is 24, so a correct
      // implementation puts it at 40.
      final p = const AnchorProjection(
        designLeadingInset: 44,
        deviceLeadingInset: 24,
      ).project(
        layout: const FigmaAxisLayout(
          anchor: FigmaAnchor.start,
          sizing: FigmaSizing.fixed,
        ),
        design: span(60, 100),
        designReference: span(0, 874),
        device: span(40, 100),
        deviceReference: span(0, 805),
      );

      expect(p.expectedPosition, 16);
      expect(p.actualPosition, 16);
    });

    test('leaves the comparison alone when no inset is declared', () {
      // Figma publishes no safe-area metadata. Rather than guess one -
      // there is no universal status-bar height - the comparison runs
      // unadjusted and the report states the device's inset so a reader
      // can see the cause of any offset.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(60, 100),
        designReference: span(0, 874),
        device: span(40, 100),
        deviceReference: span(0, 805),
      );

      expect(p.expectedPosition, 60);
      expect(p.actualPosition, 40);
    });
  });

  group('12. a mixed fixed-and-proportional layout', () {
    test('treats each axis by its own declared rule', () {
      // Real designs mix them: the Login's Continue button FILLs
      // horizontally and is FIXED vertically. Reading one rule for the
      // whole element is how a correct button gets reported as 2.1px too
      // short.
      final horizontal = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fill,
        design: span(40, 322),
        designReference: span(20, 362),
        device: span(41, 302),
        deviceReference: span(20, 344),
      );
      final vertical = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(484, 48),
        designReference: span(0, 874),
        device: span(467, 48),
        deviceReference: span(0, 805),
      );

      // The card's content box is 344 wide on the device and the button
      // is inset 20 from each side of it, so 344 - 20 - 20.
      expect(horizontal.expectedSize, 304);
      expect(vertical.expectedSize, 48, reason: 'a length is a length');
    });
  });

  group('13. and 15. a design that overflows, and an aspect mismatch', () {
    test('a filling element cannot be asked for a negative size', () {
      // A design 402 wide whose element is inset 250 on each side, on a
      // 384 viewport: the insets alone exceed the width. The design does
      // not describe this viewport, and the honest answer is to say so
      // rather than to report a negative expectation.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fill,
        design: span(250, 100),
        designReference: designFrame,
        device: span(250, 100),
        deviceReference: span(0, 300),
      );

      expect(p.expectedSize, isNull);
      expect(p.sizeSkip, contains('does not fit'));
    });

    test('an aspect mismatch is not a special case on a single axis', () {
      // Each axis is projected from its own reference, so a frame far
      // taller than the viewport affects only vertical comparisons -
      // and only through the anchors, which stay correct. There is no
      // separate aspect rule here; the screen-level guard remains where
      // it was.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(100, 50),
        designReference: span(0, 2597),
        device: span(100, 50),
        deviceReference: span(0, 805),
      );

      expect(p.expectedPosition, 100);
      expect(p.expectedSize, 50);
    });
  });

  group('14. clipping', () {
    test('is the normaliser\'s job, and a clipped box projects normally',
        () {
      // Clipping happens where the frame's `clipsContent` is known -
      // in the normaliser - so by the time a rect reaches the
      // projection it already describes what is on the screen. The
      // projection needs no clipping rule of its own.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
        design: span(0, 402),
        designReference: designFrame,
        device: span(0, 384),
        deviceReference: viewport,
      );

      expect(p.expectedSize, 402);
      expect(p.actualSize, 384);
    });
  });

  group('16. metadata the design does not provide', () {
    test('a hugged length is not compared, because it is not a length', () {
      // HUG means "as big as the content". Two text engines produce two
      // different boxes from one string, so comparing a hugged dimension
      // compares font metrics rather than layout.
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.hug,
        design: span(40, 322),
        designReference: designFrame,
        device: span(40, 291),
        deviceReference: viewport,
      );

      expect(p.expectedSize, isNull);
      expect(p.sizeSkip, contains('content'));
      // The position is still comparable: where it starts is layout.
      expect(p.expectedPosition, 40);
    });

    test('an unknown anchor skips the position rather than guessing', () {
      // `SPACE_BETWEEN` distributes children by how many there are and
      // how wide each turned out. That is not a property of the child,
      // so nothing is claimed about it.
      final p = project(
        anchor: FigmaAnchor.unknown,
        sizing: FigmaSizing.fixed,
        design: span(40, 322),
        designReference: designFrame,
        device: span(40, 322),
        deviceReference: viewport,
      );

      expect(p.expectedPosition, isNull);
      expect(p.positionSkip, isNotNull);
      // The size is still a length, and still comparable.
      expect(p.expectedSize, 322);
    });

    test('but compares anyway when the reference did not resize', () {
      // The ambiguity in "unknown" is only ever about *how a length or a
      // position changes when the frame resizes*. If the reference is
      // the same size on both sides there is no resize, every anchor
      // gives the same answer, and the length is simply the length.
      //
      // Skipping here would throw away a real check for a question
      // nobody asked - and it did: an older committed spec, which
      // predates Figma layout metadata, stopped catching a seeded
      // 24px shift on a frame exactly the shape of the viewport.
      final p = project(
        anchor: FigmaAnchor.unknown,
        sizing: FigmaSizing.unknown,
        design: span(20, 100),
        designReference: span(0, 400),
        device: span(44, 118),
        deviceReference: span(0, 400),
      );

      expect(p.expectedPosition, 20);
      expect(p.actualPosition, 44);
      expect(p.expectedSize, 100);
      expect(p.actualSize, 118);
    });

    test('and skips again as soon as the reference really did resize', () {
      final p = project(
        anchor: FigmaAnchor.unknown,
        sizing: FigmaSizing.unknown,
        design: span(20, 100),
        designReference: span(0, 400),
        device: span(20, 100),
        deviceReference: span(0, 384),
      );

      expect(p.expectedPosition, isNull);
      expect(p.expectedSize, isNull);
    });

    test('an unknown sizing skips the size rather than guessing', () {
      final p = project(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.unknown,
        design: span(40, 322),
        designReference: designFrame,
        device: span(40, 322),
        deviceReference: viewport,
      );

      expect(p.expectedSize, isNull);
      expect(p.sizeSkip, isNotNull);
    });
  });

  group('stretch', () {
    test('pins both edges, so the size gives', () {
      final p = project(
        anchor: FigmaAnchor.stretch,
        sizing: FigmaSizing.fill,
        design: span(20, 362),
        designReference: designFrame,
        device: span(20, 344),
        deviceReference: viewport,
      );

      expect(p.positionLabel, 'leading inset');
      expect(p.expectedPosition, 20);
      expect(p.expectedSize, 344);
    });
  });
}
