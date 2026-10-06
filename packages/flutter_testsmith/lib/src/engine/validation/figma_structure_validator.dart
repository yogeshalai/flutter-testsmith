import 'package:flutter_testsmith/figma.dart';
import 'package:flutter_testsmith/protocol.dart';

import 'anchor_projection.dart';
import 'figma_projection.dart';
import 'figma_tolerances.dart';
import 'validation_dimension.dart';
import 'validation_result.dart';
import 'validators.dart';

/// Compares a normalised Figma design with the captured UI tree.
///
/// Deliberately structural, not visual. This validator never looks at a
/// screenshot: it asks whether the elements the design calls for are on
/// the screen, of the right kind, in the right order, at the right size
/// and place. Pixels are Phase 7's problem.
///
/// Every check is separately identified so a report can say *which* part
/// of the design disagrees, and every threshold comes from
/// [FigmaTolerances] rather than a literal at the call site.
class FigmaStructureValidator implements ScreenValidator {
  const FigmaStructureValidator();

  @override
  String get id => 'figma-structure';

  @override
  ValidationDimension get dimension => ValidationDimension.figma;

  static const String _typeId = 'figma-type';
  static const String _geometryId = 'figma-geometry';
  static const String _orderId = 'figma-order';
  static const String _typographyId = 'figma-typography';
  static const String _colourId = 'figma-colour';
  static const String _textId = 'figma-text';
  static const String _unexpectedId = 'figma-unexpected';
  static const String _mappingId = 'figma-mapping';
  static const String _identityId = 'figma-identity';
  static const String _hierarchyId = 'figma-hierarchy';
  static const String _spacingId = 'figma-spacing';
  static const String _paddingId = 'figma-padding';
  static const String _opacityId = 'figma-opacity';
  static const String _radiusId = 'figma-radius';
  static const String _coverageId = 'figma-coverage';

  /// What the verdict is about, stated in every coverage result.
  ///
  /// A design frame holds hundreds of nodes and a mapping binds a
  /// handful. "Everything passed" is true of the handful and false of
  /// the frame, and only one of those is what a reader assumes.
  static const String _verdictScope = 'mapped elements only';

  /// Widget types that render text themselves.
  static const List<String> _textTypes = [
    'Text',
    'RichText',
    'EditableText',
    'SelectableText',
    'TextField',
    'TextFormField',
  ];

  @override
  List<ValidationResult> validate(ValidationContext context) {
    final spec = context.figmaSpec;
    if (spec == null) {
      return [
        ValidationResult.skip(
          validatorId: id,
          message: 'no Figma design is configured for '
              '${context.session.screenId}',
        ),
      ];
    }

    final results = <ValidationResult>[];

    // A mapping that points at a deleted layer is a broken tool
    // configuration, not a broken application. Surfaced as an error so
    // it blocks the pass without being read as an app defect.
    for (final nodeId in spec.unmatchedMappings) {
      results.add(
        ValidationResult.error(
          validatorId: _mappingId,
          message: 'the mapping binds Figma node "$nodeId", which is not in '
              'the "${spec.figmaName}" frame. The mapping is stale: the '
              'layer was deleted or the frame was replaced.',
        ),
      );
    }

    final snapshot = context.snapshot;
    if (snapshot == null) {
      return [
        ...results,
        ValidationResult.error(
          validatorId: id,
          // The tool could not read the UI. The design is not in
          // question, so this is not a Figma finding.
          dimension: ValidationDimension.ui,
          message: 'no UI tree was captured for this screen, so the design '
              'could not be compared',
        ),
      ];
    }

    final designed = spec.mapped;
    if (designed.isEmpty) {
      return [
        ...results,
        ValidationResult.skip(
          validatorId: id,
          message: 'the "${spec.figmaName}" design has no elements bound to '
              'semantic ids, so it cannot say anything about this screen. '
              'Add entries to the node mapping file.',
        ),
      ];
    }

    final tolerances = context.figmaTolerances;

    // Not snapshot.root.bounds: that is the union of the retained
    // nodes, which is smaller than the display whenever content stops
    // short of the edges. Projecting against it scales every coordinate
    // by the wrong factor and reports a correct layout as misplaced.
    final viewport = snapshot.viewport;
    if (viewport == null) {
      results.add(
        ValidationResult.skip(
          validatorId: _geometryId,
          message: 'the app did not report its viewport, so the design '
              'could not be projected onto the screen. Everything except '
              'geometry is still checked. Update flutter_testsmith to a version '
              'that reports it.',
        ),
      );
    }

    final projection = viewport == null
        ? null
        : DesignProjection.fitWidth(
            designWidth: spec.width,
            designHeight: spec.height,
            screenWidth: viewport.width,
            screenHeight: viewport.height,
          );

    final verticalComparable =
        projection?.verticalComparable(tolerances.aspectDelta) ?? false;
    if (projection != null && !verticalComparable) {
      results.add(
        ValidationResult.skip(
          validatorId: _geometryId,
          message: 'vertical positions were not compared: the design frame '
              'is ${_size(spec.width, spec.height)} and the viewport is '
              '${_size(viewport!.width, viewport.height)}, an aspect '
              'difference of ${(projection.aspectDelta * 100).round()}%. '
              'Horizontal position and size are still checked.',
        ),
      );
    }

    final matched = <({FigmaElement design, UiNode node})>[];

    for (final element in designed) {
      final semanticId = element.semanticId!;

      if (snapshot.duplicateTestIds.contains(semanticId)) {
        // An error, not a failure, and nothing further is compared for
        // this id. Two elements answer to it, so there is no single
        // subject to compare - and picking one would produce a verdict
        // about a node nobody chose.
        results.add(
          ValidationResult.error(
            validatorId: _identityId,
            elementId: semanticId,
            // A duplicate test id is a UI identity defect. The design is
            // not in question, so this does not belong to figma.
            dimension: ValidationDimension.ui,
            message: '"$semanticId" is on more than one element, so which '
                'one the design node "${element.figmaName}" '
                '(${element.nodeId}) refers to cannot be established. '
                'Identity is not guessed: give each element its own id.',
          ),
        );
        continue;
      }

      final node = snapshot.find(semanticId);
      if (node == null) {
        results.add(
          ValidationResult.fail(
            validatorId: id,
            elementId: semanticId,
            message: 'required design element "$semanticId" '
                '(${element.type.wire} "${element.figmaName}") is missing '
                'from the Flutter UI. Present: ${_idsIn(snapshot).join(', ')}',
            expected: semanticId,
            actual: 'absent',
            evidence: [
              Evidence(kind: 'figmaNode', reference: element.nodeId),
            ],
          ),
        );
        continue;
      }

      if (!node.visible) {
        results.add(
          ValidationResult.fail(
            validatorId: id,
            elementId: semanticId,
            message: '"$semanticId" is in the design but the element on the '
                'screen is not visible',
            expected: 'visible',
            actual: 'not visible',
          ),
        );
        continue;
      }

      matched.add((design: element, node: node));

      results.add(
        ValidationResult.pass(
          validatorId: id,
          elementId: semanticId,
          message: '"$semanticId" is present, as the design requires',
        ),
      );
    }

    // Second pass. Geometry is measured against the nearest *matched*
    // ancestor, so every element has to be matched before any of them
    // can be compared - otherwise an element would be measured against
    // the frame simply because its container had not been reached yet,
    // and the answer would depend on document order.
    final matchedByNodeId = {
      for (final m in matched) m.design.nodeId: m,
    };

    for (final entry in matched) {
      final element = entry.design;
      final node = entry.node;
      final semanticId = element.semanticId!;

      final typeResult = _checkType(element, node, semanticId);
      if (typeResult != null) results.add(typeResult);

      if (tolerances.checkGeometry && viewport != null) {
        results.add(
          _checkGeometry(
            element,
            node,
            semanticId,
            spec,
            matchedByNodeId,
            viewport,
            tolerances,
            verticalComparable: verticalComparable,
            deviceSafeArea: snapshot.safeArea,
          ),
        );
      }

      if (tolerances.checkTypography && element.typography != null) {
        results.add(
          _checkTypography(element, node, semanticId, tolerances),
        );
      }

      if (tolerances.checkColour && element.fill != null) {
        results.add(_checkColour(element, node, semanticId, tolerances));
      }

      if (tolerances.text != TextComparisonMode.ignore &&
          element.text != null) {
        results.add(_checkText(element, node, semanticId));
      }

      // Only where the design says something other than the default.
      // Every node is opaque and square-cornered unless it declares
      // otherwise, and emitting a result for each of them would bury the
      // ones that carry a statement.
      if (tolerances.checkOpacity && element.opacity != 1) {
        results.add(_checkOpacity(element, node, semanticId, tolerances));
      }

      if (tolerances.checkCornerRadius && element.cornerRadius != null) {
        results.add(_checkCornerRadius(element, node, semanticId, tolerances));
      }
    }

    if (tolerances.checkHierarchy) {
      results.addAll(_checkHierarchy(spec, snapshot, matched));
    }

    if (tolerances.checkSpacing) {
      results.addAll(
        _checkSpacing(spec, matched, tolerances,
            verticalComparable: verticalComparable),
      );
    }

    if (tolerances.checkOrdering && matched.length > 1) {
      results.add(_checkOrdering(matched));
    }

    if (tolerances.reportUnexpected) {
      results.addAll(_reportUnexpected(spec, snapshot, designed));
    }

    // Last, so it can count what everything above produced.
    results.add(_coverage(spec, results, matched.length));

    return results;
  }

  /// States what the verdict is - and is not - about.
  ///
  /// Every other result here is a judgement. This one is a denominator,
  /// and it exists because "8 checks passed" is a true sentence that
  /// reads as "the screen matches the design". It does not: it means
  /// eight of a frame's many nodes were bound to elements and those
  /// eight agreed. Coverage is the difference between those two
  /// sentences, so it is reported whether it flatters the run or not.
  ValidationResult _coverage(
    FigmaScreenSpec spec,
    List<ValidationResult> results,
    int comparedNodes,
  ) {
    final coverage = spec.coverage;

    var passed = 0;
    var failed = 0;
    var errored = 0;
    var skipped = 0;
    for (final result in results) {
      switch (result.status) {
        case ValidationStatus.pass:
          passed++;
        case ValidationStatus.fail:
          failed++;
        case ValidationStatus.error:
          errored++;
        case ValidationStatus.skip:
          skipped++;
      }
    }

    final percent = coverage.comparableNodes == 0
        ? '0.0'
        : (comparedNodes / coverage.comparableNodes * 100).toStringAsFixed(1);

    return ValidationResult.pass(
      validatorId: _coverageId,
      message: 'Figma nodes: ${coverage.totalNodes} in the '
          '"${spec.figmaName}" frame '
          '(${coverage.comparableNodes} comparable, '
          '${coverage.decorativeNodes} decorative). '
          'Mapped: ${coverage.mappedNodes}. '
          'Compared: $comparedNodes. '
          'Unmapped: ${coverage.unmappedNodes}. '
          'Coverage: $percent% of comparable nodes. '
          'Checks: $passed passed, $failed failed, $errored errored, '
          '$skipped skipped. '
          'Verdict scope: $_verdictScope.',
      facts: {
        'totalNodes': coverage.totalNodes,
        'comparableNodes': coverage.comparableNodes,
        'decorativeNodes': coverage.decorativeNodes,
        'mappedNodes': coverage.mappedNodes,
        'comparedNodes': comparedNodes,
        'unmappedNodes': coverage.unmappedNodes,
        'coveragePercent': double.parse(percent),
        'passed': passed,
        'failed': failed,
        'errored': errored,
        'skipped': skipped,
        'verdictScope': _verdictScope,
      },
    );
  }

  /// Judges the element kind, but only where the design carries a real
  /// signal.
  ///
  /// A Figma `INSTANCE` or `CONTAINER` says nothing about which Flutter
  /// widget should implement it - a button may be an `ElevatedButton`,
  /// an `InkWell` or a `GestureDetector` and all three are correct. Only
  /// TEXT and IMAGE are worth asserting on, and returning null elsewhere
  /// is better than inventing a rule nobody agreed to.
  ValidationResult? _checkType(
    FigmaElement element,
    UiNode node,
    String semanticId,
  ) {
    switch (element.type) {
      case FigmaElementType.text:
        final rendersText = _textSource(node) != null ||
            _textTypes.any((type) => node.type.contains(type));
        return rendersText
            ? ValidationResult.pass(
                validatorId: _typeId,
                elementId: semanticId,
                message: '"$semanticId" renders text, as the TEXT node in '
                    'the design requires',
              )
            : ValidationResult.fail(
                validatorId: _typeId,
                elementId: semanticId,
                message: 'the design has "$semanticId" as a TEXT node, but '
                    'the element on the screen is a ${node.type} that '
                    'renders no text',
                expected: 'TEXT',
                actual: node.type,
              );

      case FigmaElementType.image:
        return node.type.toLowerCase().contains('image')
            ? ValidationResult.pass(
                validatorId: _typeId,
                elementId: semanticId,
                message: '"$semanticId" is an image, as the design requires',
              )
            // A Container with a DecorationImage is a legitimate way to
            // render a design's IMAGE node, and the widget type alone
            // cannot tell us. Saying so beats guessing.
            : ValidationResult.skip(
                validatorId: _typeId,
                elementId: semanticId,
                message: 'the design has "$semanticId" as an IMAGE; the '
                    'element is a ${node.type}, which may or may not paint '
                    'one. Not judged.',
              );

      case FigmaElementType.shape:
      case FigmaElementType.container:
      case FigmaElementType.instance:
      case FigmaElementType.vector:
        return null;
    }
  }

  /// The horizontal behaviour to compare a text element by.
  ///
  /// The design's own declaration, wherever it makes one. The per-screen
  /// [FigmaTolerances.textAnchor] is consulted only for a TEXT element
  /// whose design declares no usable anchor, which is the case it was
  /// invented for: Figma's `textAlign` says where glyphs sit *inside*
  /// the text node's box, not how that box is anchored in its parent,
  /// and Phase 12 found that out by reporting a pixel-perfect element as
  /// 5.7px out.
  ///
  /// Kept as a fallback rather than removed. It is a human saying what
  /// the file does not, and a file that does not say still exists - an
  /// older document, a detached layer, a group Figma gives no layout
  /// metadata for.
  static FigmaAxisLayout _horizontalLayoutOf(
    FigmaElement element,
    FigmaTolerances tolerances,
  ) {
    if (element.type != FigmaElementType.text) return element.horizontal;

    // When text sizes *are* compared, the two boxes are the same size
    // and every edge agrees, so there is nothing for an anchor to
    // disambiguate and the leading edge is as good as any.
    if (tolerances.checkTextSize) {
      return const FigmaAxisLayout(
        anchor: FigmaAnchor.start,
        sizing: FigmaSizing.fixed,
      );
    }

    if (element.horizontal.anchor != FigmaAnchor.unknown) {
      return element.horizontal;
    }

    return FigmaAxisLayout(
      anchor: switch (tolerances.textAnchor) {
        TextAnchor.left => FigmaAnchor.start,
        TextAnchor.right => FigmaAnchor.end,
        TextAnchor.centre => FigmaAnchor.centre,
      },
      // A text box is typeset, so its width is its content's. That is
      // exactly what `checkTextSize: false` already says, and saying it
      // here too keeps the two from disagreeing.
      sizing: FigmaSizing.hug,
    );
  }

  /// The container an element's position is measured against.
  ///
  /// The nearest ancestor the design declares *and* the screen matched.
  /// An unmapped Figma group has no counterpart to measure against, so
  /// the walk continues past it; when nothing is matched the frame and
  /// the viewport are the reference, which is the only pair that always
  /// exists.
  ({LogicalRect design, LogicalRect device, bool isFrame}) _referenceFor(
    FigmaElement element,
    FigmaScreenSpec spec,
    Map<String, ({FigmaElement design, UiNode node})> matched,
    LogicalRect viewport,
  ) {
    for (final ancestor in spec.ancestryOf(element.nodeId)) {
      final match = matched[ancestor.nodeId];
      if (match != null) {
        return (
          design: ancestor.rect,
          device: match.node.bounds,
          isFrame: false,
        );
      }
    }
    return (
      design: LogicalRect(x: 0, y: 0, width: spec.width, height: spec.height),
      device: viewport,
      isFrame: true,
    );
  }

  static AxisSpan _x(LogicalRect r) => AxisSpan(start: r.x, size: r.width);
  static AxisSpan _y(LogicalRect r) => AxisSpan(start: r.y, size: r.height);

  /// Compares an element's geometry against the design, anchor by anchor.
  ///
  /// Nothing here is scaled. Each axis is compared as the quantity the
  /// design's own anchor holds invariant - a leading inset, a trailing
  /// inset, an offset from the centre - and each length is compared as
  /// the design declares it: fixed lengths as lengths, filling lengths
  /// against the matched parent, content-determined lengths not at all.
  ///
  /// See [AnchorProjection] for why coordinates are not multiplied by a
  /// ratio of frame widths.
  ValidationResult _checkGeometry(
    FigmaElement element,
    UiNode node,
    String semanticId,
    FigmaScreenSpec spec,
    Map<String, ({FigmaElement design, UiNode node})> matched,
    LogicalRect viewport,
    FigmaTolerances tolerances, {
    required bool verticalComparable,
    required LogicalInsets? deviceSafeArea,
  }) {
    final reference = _referenceFor(element, spec, matched, viewport);

    // The safe area shifts the origin of the *frame*, not of a container
    // inside it, so it is applied only when the frame is the reference.
    // Both sides must be known: Figma publishes no safe-area metadata,
    // so the design's inset is declared per screen or not at all, and
    // guessing one would move every top-anchored element on every screen
    // by the error.
    final applyInset = reference.isFrame &&
        tolerances.designSafeAreaTop != null &&
        deviceSafeArea != null;

    final horizontal = const AnchorProjection().project(
      layout: _horizontalLayoutOf(element, tolerances),
      design: _x(element.rect),
      designReference: _x(reference.design),
      device: _x(node.bounds),
      deviceReference: _x(reference.device),
    );

    final vertical = AnchorProjection(
      designLeadingInset: applyInset ? tolerances.designSafeAreaTop : null,
      deviceLeadingInset: applyInset ? deviceSafeArea.top : null,
    ).project(
      layout: element.vertical,
      design: _y(element.rect),
      designReference: _y(reference.design),
      device: _y(node.bounds),
      deviceReference: _y(reference.device),
    );

    // A text node's box is typeset, not laid out: its length comes from
    // the font. figma-typography already checks the font exactly.
    final comparesTextSize =
        tolerances.checkTextSize || element.type != FigmaElementType.text;

    final issues = <String>[];
    final skipped = <String>[];

    void position(String axis, AxisProjection p, {required bool enabled}) {
      if (!enabled) return;
      if (p.positionSkip != null) {
        skipped.add('$axis position: ${p.positionSkip}');
        return;
      }
      final delta = (p.actualPosition! - p.expectedPosition!).abs();
      if (delta <= tolerances.positionPx) return;
      issues.add(
        '$axis ${p.positionLabel} is ${_px(p.actualPosition!)} but the '
        'design specifies ${_px(p.expectedPosition!)} '
        '(${_px(delta)} out, tolerance ${_px(tolerances.positionPx)})',
      );
    }

    void size(String axis, AxisProjection p, {required bool enabled}) {
      if (!enabled) return;
      if (p.sizeSkip != null) {
        skipped.add('$axis: ${p.sizeSkip}');
        return;
      }
      final delta = (p.actualSize! - p.expectedSize!).abs();
      if (delta <= tolerances.sizePx) return;
      issues.add(
        '$axis is ${_px(p.actualSize!)} but the design specifies '
        '${_px(p.expectedSize!)} (${_px(delta)} out, tolerance '
        '${_px(tolerances.sizePx)})',
      );
    }

    position('horizontal', horizontal, enabled: true);
    position('vertical', vertical, enabled: verticalComparable);
    size('width', horizontal, enabled: comparesTextSize);
    size('height', vertical, enabled: comparesTextSize);

    if (issues.isNotEmpty) {
      return ValidationResult.fail(
        validatorId: _geometryId,
        elementId: semanticId,
        message: '"$semanticId" does not match the design: '
            '${issues.join('; ')}',
        expected: element.rect,
        actual: node.bounds,
        evidence: [Evidence(kind: 'figmaNode', reference: element.nodeId)],
      );
    }

    // Nothing disagreed, but nothing was compared either. Saying "pass"
    // here would be the platform claiming a check it did not make.
    final compared = (horizontal.comparesPosition && true) ||
        vertical.comparesPosition ||
        horizontal.comparesSize ||
        vertical.comparesSize;
    if (!compared) {
      return ValidationResult.skip(
        validatorId: _geometryId,
        elementId: semanticId,
        message: '"$semanticId" geometry was not compared - '
            '${skipped.join('; ')}',
      );
    }

    return ValidationResult.pass(
      validatorId: _geometryId,
      elementId: semanticId,
      message: skipped.isEmpty
          ? '"$semanticId" matches the design geometry'
          : '"$semanticId" matches the design geometry, except '
              '${skipped.join('; ')}',
      expected: element.rect,
      actual: node.bounds,
    );
  }

  /// Checks that ancestry declared in the design holds on the screen.
  ///
  /// One direction only, and deliberately so. If the design puts A
  /// inside B, B's element must contain A's element. If the design makes
  /// them siblings, nothing is asserted - Flutter trees are far deeper
  /// than design trees, and a legitimate `Padding`, `Center` or
  /// `Semantics` wrapper would otherwise read as a defect.
  ///
  /// What survives is the check that catches a real inversion: an
  /// element re-parented out of the container the design put it in,
  /// which no amount of correct geometry can excuse.
  List<ValidationResult> _checkHierarchy(
    FigmaScreenSpec spec,
    UiSnapshot snapshot,
    List<({FigmaElement design, UiNode node})> matched,
  ) {
    if (matched.length < 2) return const [];

    final byNodeId = {for (final m in matched) m.design.nodeId: m};
    final results = <ValidationResult>[];

    for (final child in matched) {
      for (final ancestor in spec.ancestryOf(child.design.nodeId)) {
        // Only ancestors that are themselves mapped and matched can be
        // spoken about; an unmapped Figma group has no counterpart to
        // look for.
        final expected = byNodeId[ancestor.nodeId];
        if (expected == null) continue;

        final childId = child.design.semanticId!;
        final ancestorId = ancestor.semanticId!;

        if (_contains(expected.node, child.node)) {
          results.add(
            ValidationResult.pass(
              validatorId: _hierarchyId,
              elementId: childId,
              message: '"$childId" is inside "$ancestorId", as the design '
                  'nests it',
            ),
          );
        } else {
          results.add(
            ValidationResult.fail(
              validatorId: _hierarchyId,
              elementId: childId,
              message: 'the design puts "$childId" inside "$ancestorId", but '
                  'on the screen it is not a descendant of it',
              expected: 'inside $ancestorId',
              actual: 'outside $ancestorId',
              evidence: [
                Evidence(kind: 'figmaNode', reference: child.design.nodeId),
              ],
            ),
          );
        }
      }
    }

    return results;
  }

  /// Whether [descendant] is somewhere below [ancestor] in the UI tree.
  ///
  /// Compared by identity: two nodes with the same bounds and type are
  /// still two nodes, and a value comparison would answer yes for the
  /// wrong one.
  static bool _contains(UiNode ancestor, UiNode descendant) {
    for (final child in ancestor.children) {
      if (identical(child, descendant)) return true;
      if (_contains(child, descendant)) return true;
    }
    return false;
  }

  /// Compares spacing, using geometry on both sides.
  ///
  /// Figma states spacing on an auto-layout frame; Flutter states it
  /// nowhere a test id can reach, because `Padding` is a separate widget
  /// that the retention policy drops. So both sides are *measured*:
  ///
  ///  * a **gap** is the distance between two adjacent mapped siblings,
  ///  * **padding** is the inset from a container to its content.
  ///
  /// Measuring both sides the same way is what makes the comparison mean
  /// something. Reading a declared number on one side and a measured one
  /// on the other would compare two different quantities.
  List<ValidationResult> _checkSpacing(
    FigmaScreenSpec spec,
    List<({FigmaElement design, UiNode node})> matched,
    FigmaTolerances tolerances, {
    required bool verticalComparable,
  }) {
    final byNodeId = {for (final m in matched) m.design.nodeId: m};
    final results = <ValidationResult>[];

    for (final container in matched) {
      final layout = container.design.layout;
      if (layout == null) continue;

      final vertical = layout.direction == FigmaLayoutDirection.vertical;
      // A vertical gap is a vertical measurement, and on a frame whose
      // aspect is too far from the viewport's those are already not
      // compared.
      if (vertical && !verticalComparable) continue;

      final children = <({FigmaElement design, UiNode node})>[
        for (final child in spec.childrenOf(container.design.nodeId))
          if (byNodeId[child.nodeId] != null) byNodeId[child.nodeId]!,
      ];

      results.addAll(_checkPadding(container, children, tolerances));

      if (children.length < 2) continue;

      for (var i = 0; i < children.length - 1; i++) {
        final previous = children[i];
        final next = children[i + 1];

        // Adjacent among *mapped* children is not adjacent in the design
        // unless nothing unmapped sits between them: an unmapped sibling
        // contributes its own height and two gaps, and none of that is
        // visible from here.
        if (!_adjacentInDesign(
          spec,
          container.design.nodeId,
          previous.design,
          next.design,
        )) {
          continue;
        }

        final designGap = vertical
            ? next.design.rect.y -
                (previous.design.rect.y + previous.design.rect.height)
            : next.design.rect.x -
                (previous.design.rect.x + previous.design.rect.width);
        final actualGap = vertical
            ? next.node.bounds.y -
                (previous.node.bounds.y + previous.node.bounds.height)
            : next.node.bounds.x -
                (previous.node.bounds.x + previous.node.bounds.width);

        // A gap is a length. It is not multiplied by a ratio of frame
        // widths, for the same reason padding is not: resizing an
        // auto-layout frame in Figma does not rescale its itemSpacing.
        final expectedGap = designGap;
        final delta = (actualGap - expectedGap).abs();
        final between = '"${previous.design.semanticId}" and '
            '"${next.design.semanticId}"';

        if (delta <= tolerances.spacingPx) {
          results.add(
            ValidationResult.pass(
              validatorId: _spacingId,
              elementId: container.design.semanticId,
              message: 'the gap between $between matches the design',
            ),
          );
        } else {
          results.add(
            ValidationResult.fail(
              validatorId: _spacingId,
              elementId: container.design.semanticId,
              message: 'the gap between $between is ${_px(actualGap)} but '
                  'the design specifies ${_px(expectedGap)} '
                  '(${_px(delta)} out, tolerance '
                  '${_px(tolerances.spacingPx)})',
              expected: _px(expectedGap),
              actual: _px(actualGap),
              evidence: [
                Evidence(
                  kind: 'figmaNode',
                  reference: container.design.nodeId,
                ),
              ],
            ),
          );
        }
      }
    }

    return results;
  }

  /// Whether nothing the design drew sits between these two children.
  static bool _adjacentInDesign(
    FigmaScreenSpec spec,
    String containerId,
    FigmaElement previous,
    FigmaElement next,
  ) {
    final all = spec.childrenOf(containerId);
    final from = all.indexWhere((e) => e.nodeId == previous.nodeId);
    final to = all.indexWhere((e) => e.nodeId == next.nodeId);
    return from >= 0 && to == from + 1;
  }

  /// Compares a container's declared padding with its measured inset.
  ///
  /// Guarded by the design's own geometry. Figma's `paddingTop` and the
  /// distance from the frame to its first child are the same number only
  /// when the frame hugs its content; on a fixed-size frame with
  /// space-between alignment they are not, and comparing them would fail
  /// an application that is correct. So each side is compared only where
  /// the design agrees with itself, and skipped where it does not.
  List<ValidationResult> _checkPadding(
    ({FigmaElement design, UiNode node}) container,
    List<({FigmaElement design, UiNode node})> children,
    FigmaTolerances tolerances,
  ) {
    final layout = container.design.layout;
    if (layout == null || layout.padding.isZero) return const [];
    if (children.isEmpty) return const [];

    // Both insets are measured from the *same* children: the mapped
    // ones, on each side. Using every retained Flutter child instead
    // would compare two different content boxes - partial mapping is the
    // normal case, and an unmapped full-bleed divider inside a card puts
    // Flutter's inset at 0 against the design's 20.
    final designInset = _insetOf(
      container.design.rect,
      [for (final c in children) c.design.rect],
    );
    final actualInset = _insetOf(
      container.node.bounds,
      [for (final c in children) c.node.bounds],
    );

    final declared = layout.padding;
    final id = container.design.semanticId;

    final sides = <String, ({double declared, double design, double actual})>{
      'left': (
        declared: declared.left,
        design: designInset.left,
        actual: actualInset.left,
      ),
      'top': (
        declared: declared.top,
        design: designInset.top,
        actual: actualInset.top,
      ),
      'right': (
        declared: declared.right,
        design: designInset.right,
        actual: actualInset.right,
      ),
      'bottom': (
        declared: declared.bottom,
        design: designInset.bottom,
        actual: actualInset.bottom,
      ),
    };

    final issues = <String>[];
    final notHugging = <String>[];
    var compared = 0;

    for (final entry in sides.entries) {
      final side = entry.value;
      if (side.declared == 0) continue;

      if ((side.declared - side.design).abs() > tolerances.spacingPx) {
        notHugging.add(entry.key);
        continue;
      }

      compared++;
      // Declared padding is a length; see _checkSpacing.
      final expected = side.declared;
      final delta = (side.actual - expected).abs();
      if (delta > tolerances.spacingPx) {
        issues.add(
          '${entry.key} padding is ${_px(side.actual)} but the design '
          'specifies ${_px(expected)} (${_px(delta)} out)',
        );
      }
    }

    final results = <ValidationResult>[];

    if (notHugging.isNotEmpty) {
      results.add(
        ValidationResult.skip(
          validatorId: _paddingId,
          elementId: id,
          message: 'the ${notHugging.join(', ')} padding of "$id" was not '
              'compared: the design declares it but does not hug its '
              'content there, so the declared padding and the measured '
              'inset are not the same distance',
        ),
      );
    }

    if (compared == 0) return results;

    if (issues.isEmpty) {
      results.add(
        ValidationResult.pass(
          validatorId: _paddingId,
          elementId: id,
          message: '"$id" matches the design padding',
        ),
      );
    } else {
      results.add(
        ValidationResult.fail(
          validatorId: _paddingId,
          elementId: id,
          message: '"$id" padding differs: ${issues.join('; ')} '
              '(tolerance ${_px(tolerances.spacingPx)})',
          expected: declared.toString(),
          actual: actualInset.toString(),
          evidence: [
            Evidence(kind: 'figmaNode', reference: container.design.nodeId),
          ],
        ),
      );
    }

    return results;
  }

  /// The inset from [outer] to the union of [inner].
  static FigmaEdgeInsets _insetOf(LogicalRect outer, List<LogicalRect> inner) {
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;

    for (final rect in inner) {
      if (rect.x < left) left = rect.x;
      if (rect.y < top) top = rect.y;
      if (rect.x + rect.width > right) right = rect.x + rect.width;
      if (rect.y + rect.height > bottom) bottom = rect.y + rect.height;
    }

    return FigmaEdgeInsets(
      left: left - outer.x,
      top: top - outer.y,
      right: (outer.x + outer.width) - right,
      bottom: (outer.y + outer.height) - bottom,
    );
  }

  ValidationResult _checkOpacity(
    FigmaElement element,
    UiNode node,
    String semanticId,
    FigmaTolerances tolerances,
  ) {
    final actual = _toDouble(node.properties['opacity']);
    if (actual == null) {
      return ValidationResult.skip(
        validatorId: _opacityId,
        elementId: semanticId,
        message: 'the design draws "$semanticId" at '
            '${_ratio(element.opacity)} opacity, but the app reported no '
            'opacity for it. The element the id names is not an opacity '
            'render object, and the inspector does not look below it.',
      );
    }

    final delta = (actual - element.opacity).abs();
    if (delta <= tolerances.opacityDelta) {
      return ValidationResult.pass(
        validatorId: _opacityId,
        elementId: semanticId,
        message: '"$semanticId" matches the design opacity',
      );
    }

    return ValidationResult.fail(
      validatorId: _opacityId,
      elementId: semanticId,
      message: '"$semanticId" is drawn at ${_ratio(actual)} opacity but the '
          'design specifies ${_ratio(element.opacity)} '
          '(tolerance ${_ratio(tolerances.opacityDelta)})',
      expected: _ratio(element.opacity),
      actual: _ratio(actual),
      evidence: [Evidence(kind: 'figmaNode', reference: element.nodeId)],
    );
  }

  ValidationResult _checkCornerRadius(
    FigmaElement element,
    UiNode node,
    String semanticId,
    FigmaTolerances tolerances,
  ) {
    final expected = element.cornerRadius!;
    final actual = _toDouble(node.properties['cornerRadius']);
    if (actual == null) {
      return ValidationResult.skip(
        validatorId: _radiusId,
        elementId: semanticId,
        message: 'the design gives "$semanticId" a corner radius of '
            '${_px(expected)}, but the app reported none. The element the '
            'id names is not a decorated render object, and the inspector '
            'does not look below it.',
      );
    }

    final delta = (actual - expected).abs();
    if (delta <= tolerances.cornerRadiusPx) {
      return ValidationResult.pass(
        validatorId: _radiusId,
        elementId: semanticId,
        message: '"$semanticId" matches the design corner radius',
      );
    }

    return ValidationResult.fail(
      validatorId: _radiusId,
      elementId: semanticId,
      message: '"$semanticId" has a corner radius of ${_px(actual)} but the '
          'design specifies ${_px(expected)} (${_px(delta)} out, tolerance '
          '${_px(tolerances.cornerRadiusPx)})',
      expected: _px(expected),
      actual: _px(actual),
      evidence: [Evidence(kind: 'figmaNode', reference: element.nodeId)],
    );
  }

  static String _ratio(double value) => value.toStringAsFixed(2);

  ValidationResult _checkTypography(
    FigmaElement element,
    UiNode node,
    String semanticId,
    FigmaTolerances tolerances,
  ) {
    final typography = element.typography!;
    // The style lives on whatever paints the text, which is not always
    // the node carrying the id.
    final styled = _textSource(node) ?? node;
    final fontSize = _toDouble(styled.properties['fontSize']);
    final fontWeight = _toInt(styled.properties['fontWeight']);
    final fontFamily = styled.properties['fontFamily'] as String?;

    if (fontSize == null && fontWeight == null && fontFamily == null) {
      return ValidationResult.skip(
        validatorId: _typographyId,
        elementId: semanticId,
        message: 'the app reported no text style for "$semanticId", so '
            'typography was not compared',
      );
    }

    final issues = <String>[];

    if (fontSize != null &&
        (fontSize - typography.fontSize).abs() > tolerances.fontSizePx) {
      issues.add(
        'font size is ${_px(fontSize)}, the design specifies '
        '${_px(typography.fontSize)}',
      );
    }

    if (fontWeight != null &&
        (fontWeight - typography.fontWeight).abs() >
            tolerances.fontWeightSteps * 100) {
      issues.add(
        'font weight is $fontWeight, the design specifies '
        '${typography.fontWeight}',
      );
    }

    if (tolerances.checkFontFamily && fontFamily != null) {
      final actual = _normaliseFamily(fontFamily);
      final expected = _normaliseFamily(typography.fontFamily);
      if (actual != expected) {
        issues.add(
          'font family is "$fontFamily", the design specifies '
          '"${typography.fontFamily}"',
        );
      }
    }

    if (issues.isEmpty) {
      return ValidationResult.pass(
        validatorId: _typographyId,
        elementId: semanticId,
        message: '"$semanticId" matches the design typography',
      );
    }

    return ValidationResult.fail(
      validatorId: _typographyId,
      elementId: semanticId,
      message: '"$semanticId" typography differs: ${issues.join('; ')}',
      expected: typography.toString(),
      actual: '${fontFamily ?? 'unknown'} '
          '${fontSize == null ? '?' : _px(fontSize)} w${fontWeight ?? '?'}',
    );
  }

  ValidationResult _checkColour(
    FigmaElement element,
    UiNode node,
    String semanticId,
    FigmaTolerances tolerances,
  ) {
    // Which side to read is decided by the *design*, not by what the
    // screen happens to carry.
    //
    // A TEXT node's fill is the colour of its glyphs, so the text is
    // read - including from a descendant, because the id belongs on the
    // button and the design's TEXT node describes the label inside it.
    // Any other node's fill is the colour *behind* its content, so the
    // element's own paint is read and nothing below it is consulted.
    //
    // Measured on the real application, which is how the rule was
    // arrived at: the Continue button's design node is a near-white
    // 322x48 frame and the Flutter node with that id contains a
    // near-black label. Descending to the label reported the button as
    // 229 channels out - a difference the comparison had invented.
    final actual = element.type == FigmaElementType.text
        ? _Rgba.tryParse((_textSource(node) ?? node).properties['color'])
        : _Rgba.tryParse(node.properties['fill']);
    if (actual == null) {
      return ValidationResult.skip(
        validatorId: _colourId,
        elementId: semanticId,
        message: 'the app reported no colour for "$semanticId", so it was '
            'not compared with the design. A shape reports one only when '
            'the element the id names is a decorated render object.',
      );
    }

    final expected = _Rgba.tryParse(element.fill);
    if (expected == null) {
      return ValidationResult.error(
        validatorId: _colourId,
        elementId: semanticId,
        message: 'the design fill "${element.fill}" is not a colour this '
            'validator can read',
      );
    }

    final delta = expected.maxChannelDelta(actual);
    if (delta <= tolerances.colourChannelDelta) {
      return ValidationResult.pass(
        validatorId: _colourId,
        elementId: semanticId,
        message: '"$semanticId" matches the design colour',
      );
    }

    return ValidationResult.fail(
      validatorId: _colourId,
      elementId: semanticId,
      message: '"$semanticId" is ${actual.hex} but the design specifies '
          '${expected.hex} (channel difference $delta, tolerance '
          '${tolerances.colourChannelDelta})',
      expected: expected.hex,
      actual: actual.hex,
    );
  }

  ValidationResult _checkText(
    FigmaElement element,
    UiNode node,
    String semanticId,
  ) {
    final actual = _textSource(node)?.text;
    if (actual == null) {
      return ValidationResult.skip(
        validatorId: _textId,
        elementId: semanticId,
        message: '"$semanticId" renders no text to compare with the design',
      );
    }

    if (actual.trim() == element.text!.trim()) {
      return ValidationResult.pass(
        validatorId: _textId,
        elementId: semanticId,
        message: '"$semanticId" matches the design copy',
      );
    }

    return ValidationResult.fail(
      validatorId: _textId,
      elementId: semanticId,
      message: '"$semanticId" reads "$actual" but the design says '
          '"${element.text}"',
      expected: element.text,
      actual: actual,
    );
  }

  /// Compares top-to-bottom order rather than absolute position.
  ///
  /// Ordering survives the scaling and scroll-offset problems that make
  /// absolute vertical comparison unreliable, so it catches a swapped
  /// layout even on a screen where y cannot be compared at all.
  ValidationResult _checkOrdering(
    List<({FigmaElement design, UiNode node})> matched,
  ) {
    final byDesign = [...matched]
      ..sort((a, b) => a.design.rect.y.compareTo(b.design.rect.y));
    final byScreen = [...matched]
      ..sort((a, b) => a.node.bounds.y.compareTo(b.node.bounds.y));

    final expected = [for (final m in byDesign) m.design.semanticId!];
    final actual = [for (final m in byScreen) m.design.semanticId!];

    if (_sameOrder(expected, actual)) {
      return ValidationResult.pass(
        validatorId: _orderId,
        message: 'the ${expected.length} mapped elements appear in the '
            'order the design lays them out',
      );
    }

    return ValidationResult.fail(
      validatorId: _orderId,
      message: 'elements are not in the design\'s top-to-bottom order. '
          'Design: ${expected.join(' -> ')}. Screen: ${actual.join(' -> ')}.',
      expected: expected.join(' -> '),
      actual: actual.join(' -> '),
    );
  }

  Iterable<ValidationResult> _reportUnexpected(
    FigmaScreenSpec spec,
    UiSnapshot snapshot,
    List<FigmaElement> designed,
  ) {
    final inDesign = {for (final element in designed) element.semanticId};
    return [
      for (final testId in _idsIn(snapshot))
        if (!inDesign.contains(testId))
          ValidationResult.fail(
            validatorId: _unexpectedId,
            elementId: testId,
            message: '"$testId" is on the screen but is not in the '
                '"${spec.figmaName}" design',
            severity: Severity.warning,
          ),
    ];
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The node that actually renders this element's text.
  ///
  /// A semantic id belongs on the widget a person interacts with, while
  /// the design's TEXT node describes the label inside it:
  /// `FilledButton(key: TestKey('product.add_to_cart'), child: Text(..))`
  /// is the ordinary shape, and judging the button by its own - absent -
  /// text would fail every button on every screen.
  ///
  /// Only an unambiguous descendant counts. With two text children there
  /// is no single label, and choosing one would be a guess dressed up as
  /// a result.
  static UiNode? _textSource(UiNode node) {
    if (node.text != null && node.text!.isNotEmpty) return node;

    final bearers = <UiNode>[];
    void walk(UiNode current) {
      for (final child in current.children) {
        if (child.text != null && child.text!.isNotEmpty) bearers.add(child);
        walk(child);
      }
    }

    walk(node);
    return bearers.length == 1 ? bearers.single : null;
  }

  static List<String> _idsIn(UiSnapshot snapshot) =>
      snapshot.root.testIds.toList()..sort();

  static String _px(double value) => '${value.toStringAsFixed(1)}px';

  static String _size(double width, double height) =>
      '${width.round()}x${height.round()}';

  /// Strips the `packages/<package>/` prefix Flutter adds to bundled
  /// fonts, so a family is compared by the name a designer would use.
  static String _normaliseFamily(String family) {
    final stripped = family.startsWith('packages/')
        ? family.split('/').last
        : family;
    return stripped.trim().toLowerCase();
  }

  static double? _toDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  static int? _toInt(Object? value) => value is num ? value.round() : null;
}

/// An 8-bit colour, read from either the platform's `#rrggbbaa` text or
/// a raw Flutter ARGB integer.
class _Rgba {
  const _Rgba(this.r, this.g, this.b, this.a);

  final int r;
  final int g;
  final int b;
  final int a;

  static _Rgba? tryParse(Object? value) {
    if (value is int) {
      // Flutter's Color.value is 0xAARRGGBB.
      return _Rgba(
        (value >> 16) & 0xff,
        (value >> 8) & 0xff,
        value & 0xff,
        (value >> 24) & 0xff,
      );
    }
    if (value is! String) return null;

    final hex = value.startsWith('#') ? value.substring(1) : value;
    if (hex.length != 6 && hex.length != 8) return null;

    int? channel(int index) =>
        int.tryParse(hex.substring(index * 2, index * 2 + 2), radix: 16);

    final r = channel(0);
    final g = channel(1);
    final b = channel(2);
    final a = hex.length == 8 ? channel(3) : 255;
    if (r == null || g == null || b == null || a == null) return null;

    return _Rgba(r, g, b, a);
  }

  int maxChannelDelta(_Rgba other) => [
        (r - other.r).abs(),
        (g - other.g).abs(),
        (b - other.b).abs(),
        (a - other.a).abs(),
      ].reduce((a, b) => a > b ? a : b);

  String get hex => '#${_hex(r)}${_hex(g)}${_hex(b)}${_hex(a)}';

  static String _hex(int value) => value.toRadixString(16).padLeft(2, '0');
}
