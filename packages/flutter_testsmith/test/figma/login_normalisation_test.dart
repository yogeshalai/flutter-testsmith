import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith/figma.dart';
import 'package:test/test.dart';

/// A `Login` frame captured from `GET /v1/files/{key}/nodes?ids=909:1`.
///
/// Geometry, typography, colour and structure are as Figma returned
/// them. Client-identifying names and text, node ids, component keys,
/// image refs and file metadata were replaced with synthetic values, and
/// `thumbnailUrl` - a presigned S3 link carrying AWS credential
/// material - was removed.
///
/// Every number asserted below was read out of this response, not chosen
/// to make a comparison work.
Map<String, Object?> loadLogin() => jsonDecode(
      File('test/figma/fixtures/login_node.json').readAsStringSync(),
    ) as Map<String, Object?>;

FigmaScreenSpec normaliseLogin({FigmaNodeMapping? mapping}) =>
    const FigmaNormaliser().normalise(
      loadLogin(),
      nodeId: '909:1',
      screen: '/login',
      mapping: mapping,
    );

void main() {
  group('hierarchy', () {
    final spec = normaliseLogin();

    test('records the parent of each element', () {
      // "Welcome!" sits inside Frame 427318353, which the real response
      // shows at 909:17.
      expect(spec.byNodeId('909:18')!.parentNodeId, '909:17');
    });

    test('leaves a direct child of the frame without a parent', () {
      // 909:15 is a top-level child of the Login frame itself.
      expect(spec.byNodeId('909:15')!.parentNodeId, isNull);
    });

    test('reconstructs the children of a node', () {
      expect(
        spec.childrenOf('909:16').map((e) => e.nodeId),
        ['909:17', '909:20', '909:129', '909:133'],
      );
    });

    test('reconstructs the ancestry of a node, nearest first', () {
      expect(
        spec.ancestryOf('909:128').map((e) => e.nodeId),
        ['909:127', '909:20', '909:16', '909:15'],
      );
    });

    test('reports whether one node is an ancestor of another', () {
      expect(spec.isAncestor(ancestor: '909:16', descendant: '909:128'),
          isTrue);
      expect(spec.isAncestor(ancestor: '909:128', descendant: '909:16'),
          isFalse);
      // Siblings are not ancestors of one another.
      expect(spec.isAncestor(ancestor: '909:17', descendant: '909:20'),
          isFalse);
    });
  });

  group('opacity', () {
    final spec = normaliseLogin();

    test('is read from the node', () {
      // The background artwork the Login frame lays under everything.
      // The running application wraps the same asset in
      // `Opacity(opacity: 0.20, ...)`; neither number was copied from
      // the other.
      expect(spec.byNodeId('909:2')!.opacity, closeTo(0.2, 0.0001));
      expect(spec.byNodeId('917:2')!.opacity, closeTo(0.6, 0.0001));
    });

    test('defaults to fully opaque when the node does not say', () {
      expect(spec.byNodeId('909:18')!.opacity, 1);
    });

    test('is kept separate from the fill alpha', () {
      // Figma's node opacity and a fill entry's own opacity are
      // different things, and Flutter agrees: `Opacity` is a different
      // render object from the decoration colour. Folding one into the
      // other would report a colour that is on neither side.
      final faded = spec.byNodeId('917:2')!;

      expect(faded.opacity, closeTo(0.6, 0.0001));
      expect(faded.fill, endsWith('ff'));
    });
  });

  group('visibility', () {
    test('every node in this real frame is visible', () {
      // Recorded rather than assumed: neither real frame this milestone
      // uses contains a hidden layer, so the false branch is covered by
      // the parser test below rather than by the fixture.
      expect(normaliseLogin().elements.every((e) => e.visible), isTrue);
    });

    test('a node marked hidden is carried through as hidden', () {
      // A parser test, not a design. The smallest response shape that
      // exercises the branch the real fixtures cannot.
      final spec = const FigmaNormaliser().normalise(
        {
          'nodes': {
            '1:1': {
              'document': {
                'id': '1:1',
                'name': 'Frame',
                'type': 'FRAME',
                'absoluteBoundingBox': {
                  'x': 0,
                  'y': 0,
                  'width': 100,
                  'height': 100,
                },
                'children': [
                  {
                    'id': '1:2',
                    'name': 'Hidden',
                    'type': 'RECTANGLE',
                    'visible': false,
                    'absoluteBoundingBox': {
                      'x': 0,
                      'y': 0,
                      'width': 10,
                      'height': 10,
                    },
                  },
                ],
              },
            },
          },
        },
        nodeId: '1:1',
        screen: '/x',
      );

      expect(spec.byNodeId('1:2')!.visible, isFalse);
    });
  });

  group('auto-layout', () {
    final spec = normaliseLogin();

    test('reads spacing and padding off an auto-layout frame', () {
      final card = spec.byNodeId('909:16')!.layout!;

      expect(card.direction, FigmaLayoutDirection.vertical);
      expect(card.itemSpacing, 20);
      expect(card.padding.left, 20);
      expect(card.padding.top, 24);
      expect(card.padding.right, 20);
      expect(card.padding.bottom, 24);
    });

    test('reports absent padding as zero, not as unknown', () {
      final outer = spec.byNodeId('909:15')!.layout!;

      expect(outer.direction, FigmaLayoutDirection.vertical);
      expect(outer.itemSpacing, 12);
      expect(outer.padding, FigmaEdgeInsets.zero);
    });

    test('reads a horizontal row', () {
      final row = spec.byNodeId('909:23')!.layout!;

      expect(row.direction, FigmaLayoutDirection.horizontal);
      expect(row.itemSpacing, 16);
      expect(row.padding.left, 16);
      expect(row.padding.top, 14);
    });

    test('is absent on a node that is not an auto-layout frame', () {
      expect(spec.byNodeId('909:18')!.layout, isNull);
    });
  });

  group('coverage', () {
    // Eight real node ids out of the Login frame. Nothing about the
    // frame changes when a mapping is supplied: the counts below are
    // the frame's, and only `mappedNodes` moves.
    final mapping = FigmaNodeMapping.parse('''
screen: /login
nodes:
  "909:16": login.card
  "909:18": login.welcome_title
  "909:19": login.welcome_subtitle
  "909:125": login.country_code
  "909:126": login.mobile_field
  "909:128": login.continue_label
  "909:140": login.google_label
  "909:146": login.skip_label
''', source: 'test');

    test('counts every node in the frame, not just the comparable ones', () {
      // 181 nodes sit inside the real Login frame. Reporting only the
      // 90 that survive pruning would let "8 of 8 passed" read as "the
      // screen passed".
      expect(normaliseLogin().coverage.totalNodes, 181);
    });

    test('separates comparable nodes from decorative ones', () {
      final coverage = normaliseLogin().coverage;

      expect(coverage.comparableNodes, 90);
      // Vector paths inside icon groups, and nodes laid out to nothing.
      expect(coverage.decorativeNodes, 91);
      expect(
        coverage.comparableNodes + coverage.decorativeNodes,
        coverage.totalNodes,
      );
    });

    test('counts mapped and unmapped comparable nodes', () {
      final coverage = normaliseLogin(mapping: mapping).coverage;

      expect(coverage.mappedNodes, 8);
      expect(coverage.unmappedNodes, 82);
    });

    test('states the mapped fraction of the comparable design', () {
      final coverage = normaliseLogin(mapping: mapping).coverage;

      expect(coverage.mappedFraction, closeTo(8 / 90, 0.0001));
    });

    test('is zero-mapped, not divide-by-zero, with no mapping at all', () {
      final coverage = normaliseLogin().coverage;

      expect(coverage.mappedNodes, 0);
      expect(coverage.mappedFraction, 0);
    });
  });
}
