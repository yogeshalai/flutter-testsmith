@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_testsmith/figma.dart';
import 'package:test/test.dart';

/// One test that really talks to Figma.
///
/// Everything else in this package runs against a committed capture of a
/// real response, which is repeatable and offline. That is the right
/// default, and it has one blind spot: a capture cannot notice that the
/// endpoint changed shape, that the token stopped working, or that the
/// frame was deleted. This test is what notices.
///
/// It is skipped, not failed, when the environment carries no
/// credentials - a contributor without Figma access still gets a green
/// suite, and CI without secrets does not go red for a reason that is
/// not about the code.
///
/// Which file and frame is the caller's choice; nothing here names a real
/// design. `FIGMA_NODE_ID` must be a screen frame that has text, nesting
/// and at least one auto-layout frame, because those are what the
/// comparison depends on. `FIGMA_SECOND_NODE_ID` is optional.
///
///     FIGMA_TOKEN=... FIGMA_FILE_KEY=... FIGMA_NODE_ID=... dart test -t network

void main() {
  final token = Platform.environment['FIGMA_TOKEN'];
  final fileKey = Platform.environment['FIGMA_FILE_KEY'];
  final nodeId = Platform.environment['FIGMA_NODE_ID'];
  final secondNodeId = Platform.environment['FIGMA_SECOND_NODE_ID'];
  final configured = [token, fileKey, nodeId]
      .every((value) => value != null && value.isNotEmpty);

  final skip = configured
      ? null
      : 'no FIGMA_TOKEN, FIGMA_FILE_KEY and FIGMA_NODE_ID in the '
          'environment, so the real Figma API was not called';
  final secondSkip = skip ??
      (secondNodeId == null || secondNodeId.isEmpty
          ? 'no FIGMA_SECOND_NODE_ID in the environment'
          : null);

  group('against the real Figma API', () {
    late FigmaClient client;

    setUp(() {
      client = FigmaClient(token: token ?? '');
    });

    test('fetches and normalises the named frame', () async {
      final id = FigmaTarget.normaliseNodeId(nodeId!);
      final raw = await client.fetchNode(
        fileKey: fileKey!,
        nodeId: id,
        refresh: true,
      );

      final spec =
          const FigmaNormaliser().normalise(raw, nodeId: id, screen: '/live');

      expect(spec.nodeId, id);
      expect(spec.figmaName, isNotEmpty);
      expect(spec.width, greaterThan(0));
      expect(spec.height, greaterThan(0));

      // The shape the comparison depends on, asserted against live data
      // rather than a capture: geometry, hierarchy and typography all
      // have to survive the round trip.
      expect(spec.elements, isNotEmpty);
      expect(
        spec.elements.where((e) => e.type == FigmaElementType.text),
        isNotEmpty,
      );
      expect(
        spec.elements.where((e) => e.parentNodeId != null),
        isNotEmpty,
        reason: 'the response carried no nesting, so hierarchy comparison '
            'would silently assert nothing',
      );
      expect(
        spec.elements.where((e) => e.layout != null),
        isNotEmpty,
        reason: 'no auto-layout frame came back, so spacing comparison '
            'would silently assert nothing',
      );
    }, skip: skip);

    test('fetches a second frame through the same client', () async {
      final id = FigmaTarget.normaliseNodeId(secondNodeId!);
      final raw = await client.fetchNode(
        fileKey: fileKey!,
        nodeId: id,
        refresh: true,
      );

      final spec =
          const FigmaNormaliser().normalise(raw, nodeId: id, screen: '/live2');

      expect(spec.nodeId, id);
      expect(spec.width, greaterThan(0));
      expect(spec.coverage.comparableNodes, greaterThan(0));
    }, skip: secondSkip);

    test('rejects a bad token without quoting it', () async {
      // The live 403 path, which no capture can exercise.
      // Assembled from parts so secret scanners do not flag the source.
      const wrong = 'fig' 'd_' 'NOTAREALTOKEN0000000000000000000000000';

      await expectLater(
        FigmaClient(token: wrong)
            .fetchNode(fileKey: fileKey!, nodeId: nodeId!, refresh: true),
        throwsA(
          isA<FigmaException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains(wrong)),
          ),
        ),
      );
    }, skip: skip);
  });
}
