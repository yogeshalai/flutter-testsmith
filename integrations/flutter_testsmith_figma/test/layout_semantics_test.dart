import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:test/test.dart';

/// What the real Login frame says about how each element resizes.
///
/// A design coordinate is not a scalable quantity. It is an inset from an
/// anchor, and Figma declares which anchor - through auto-layout
/// alignment for a child of an auto-layout frame, and through
/// `constraints` for an absolutely positioned one. Both appear in this
/// one real frame, which is why it is the fixture.
///
/// Every expectation below was read out of the response.
Map<String, Object?> loadLogin() => jsonDecode(
      File('test/fixtures/login_node.json').readAsStringSync(),
    ) as Map<String, Object?>;

FigmaScreenSpec spec() => const FigmaNormaliser()
    .normalise(loadLogin(), nodeId: '909:1', screen: '/login');

FigmaElement node(String id) => spec().byNodeId(id)!;

void main() {
  group('an auto-layout child takes its anchor from the parent', () {
    test('main-axis MAX end-anchors the child', () {
      // 909:144 is a HORIZONTAL auto-layout row with
      // primaryAxisAlignItems: MAX. Its child is therefore pinned to the
      // row's trailing edge, 20px in - which is the row's paddingRight.
      // The "Skip" pill is the real element this describes.
      expect(node('909:145').horizontal.anchor, FigmaAnchor.end);
    });

    test('cross-axis CENTER centre-anchors the child', () {
      // 909:15 is VERTICAL with counterAxisAlignItems: CENTER, so its
      // children are centred horizontally.
      expect(node('909:141').horizontal.anchor, FigmaAnchor.centre);
      expect(node('909:129').horizontal.anchor, FigmaAnchor.centre);
    });

    test('layoutAlign STRETCH overrides the parent cross-axis alignment', () {
      // The card declares STRETCH, so it fills its parent's width
      // regardless of the parent's CENTER.
      expect(node('909:16').horizontal.anchor, FigmaAnchor.stretch);
    });

    test('a vertical stack start-anchors its children on the main axis', () {
      // primaryAxisAlignItems is absent, which is Figma's MIN.
      expect(node('909:129').vertical.anchor, FigmaAnchor.start);
    });
  });

  group('an absolutely positioned child takes its anchor from constraints',
      () {
    test('LEFT/TOP is start on both axes', () {
      expect(node('909:2').horizontal.anchor, FigmaAnchor.start);
      expect(node('909:2').vertical.anchor, FigmaAnchor.start);
    });

    test('CENTER is centre-anchored', () {
      // The logo, 164x164, genuinely centred in the frame.
      expect(node('909:3').horizontal.anchor, FigmaAnchor.centre);
    });

    test('BOTTOM is end-anchored', () {
      // The "App developed by" row, which the design really does pin to
      // the bottom of the frame.
      expect(node('917:1').vertical.anchor, FigmaAnchor.end);
      expect(node('917:1').horizontal.anchor, FigmaAnchor.centre);
    });
  });

  group('sizing says whether a length is a length', () {
    test('FIXED is a fixed length', () {
      // The design says this button is 48 tall. That is 48, not 48
      // scaled by the ratio of two frame widths.
      expect(node('909:127').vertical.sizing, FigmaSizing.fixed);
      expect(node('909:141').horizontal.sizing, FigmaSizing.fixed);
    });

    test('HUG is determined by content, so it is not a design length', () {
      // Two text engines produce two different content boxes from one
      // string. Comparing them compares fonts, not layout.
      expect(node('909:16').vertical.sizing, FigmaSizing.hug);
      expect(node('909:125').horizontal.sizing, FigmaSizing.hug);
    });

    test('FILL is determined by the parent', () {
      expect(node('909:16').horizontal.sizing, FigmaSizing.fill);
      expect(node('909:127').horizontal.sizing, FigmaSizing.fill);
    });

    test('an absolute child with a one-sided constraint is fixed', () {
      expect(node('909:2').horizontal.sizing, FigmaSizing.fixed);
    });
  });

  group('clipping', () {
    test('reports that the frame clips its content', () {
      expect(spec().clipsContent, isTrue);
    });

    test('clips an element that overflows a clipping frame', () {
      // The background artwork is authored 542.7 wide inside a 402-wide
      // frame. Figma clips it, so 140px of it is not on the screen and
      // comparing the unclipped box against a rendered one is comparing
      // against something nobody can see.
      final background = node('909:2');

      expect(background.rect.x, 0);
      expect(background.rect.width, 402);
    });

    test('records the unclipped box, so the clipping is visible', () {
      expect(node('909:2').unclippedRect!.width, closeTo(542.7, 0.1));
    });

    test('leaves an element that fits alone', () {
      // Not clamped - it never crossed the frame edge.
      final card = node('909:16');

      expect(card.rect.x, 20);
      expect(card.rect.width, 362);
      expect(card.unclippedRect, isNull);
    });
  });
}
