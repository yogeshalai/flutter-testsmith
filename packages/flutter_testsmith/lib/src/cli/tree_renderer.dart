import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'output.dart';

/// Renders a captured tree as readable, indented text.
///
/// The tree is the primary functional record, so it has to be legible to a
/// person diagnosing a failure - not just parseable by the engine.
class TreeRenderer {
  const TreeRenderer(this.output);

  final Output output;

  void render(UiSnapshot snapshot) {
    output
      ..line(output.bold('UI tree: ${snapshot.screenId}'))
      ..line()
      ..line('  captured          ${snapshot.capturedAt.toIso8601String()}')
      ..line('  devicePixelRatio  ${snapshot.devicePixelRatio}')
      ..line('  retained nodes    ${snapshot.retainedNodeCount}')
      ..line('  elements walked   ${snapshot.totalElementsWalked}')
      ..line('  filtered away     ${_filteredPercent(snapshot)}');

    if (snapshot.hasAmbiguousIds) {
      output
        ..line()
        ..line(output.red(
          '  ambiguous ids: ${snapshot.duplicateTestIds.join(', ')}',
        ))
        ..line(output.dim(
          '  An id on more than one element makes any assertion about it '
          'meaningless.',
        ));
    }

    output..line()..line(output.bold('  Tree'));
    _renderNode(snapshot.root, 0);

    final ids = _testIds(snapshot.root);
    output
      ..line()
      ..line('  test ids (${ids.length}): ${ids.isEmpty ? '-' : ids.join(', ')}')
      ..line();
  }

  void _renderNode(UiNode node, int depth) {
    final indent = '    ${'  ' * depth}';
    final id = node.testId == null ? '' : output.green(' #${node.testId}');
    final text = node.text == null ? '' : ' "${_clip(node.text!)}"';
    final label = node.label == null ? '' : output.dim(' [${node.label}]');
    final enabled = switch (node.enabled) {
      true => output.dim(' enabled'),
      false => output.yellow(' disabled'),
      null => '',
    };
    final hidden = node.visible ? '' : output.yellow(' hidden');
    final b = node.bounds;
    final bounds = output.dim(
      ' (${_n(b.x)},${_n(b.y)} ${_n(b.width)}x${_n(b.height)})',
    );

    output.line('$indent${node.type}$id$text$label$enabled$hidden$bounds');

    for (final child in node.children) {
      _renderNode(child, depth + 1);
    }
  }

  static String _filteredPercent(UiSnapshot snapshot) {
    if (snapshot.totalElementsWalked == 0) return '-';
    final dropped =
        snapshot.totalElementsWalked - snapshot.retainedNodeCount;
    final percent =
        (dropped / snapshot.totalElementsWalked * 100).toStringAsFixed(1);
    return '$dropped ($percent%)';
  }

  static List<String> _testIds(UiNode node) => [
        ?node.testId,
        for (final child in node.children) ..._testIds(child),
      ];

  static String _clip(String text) =>
      text.length <= 40 ? text : '${text.substring(0, 37)}...';

  static String _n(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : value.toStringAsFixed(1);
}
