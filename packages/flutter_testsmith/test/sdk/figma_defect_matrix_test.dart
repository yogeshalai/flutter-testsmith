@Tags(['figma-matrix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith/figma.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith/flutter_testsmith.dart';

/// Seeded Flutter-side defects, and the verdict each one must produce.
///
/// Every side of this is real:
///
///  * the **design** is the `Login` frame (`909:1`) captured from the
///    Figma REST API - real geometry and typography, with identifying
///    names and text, ids and keys replaced by synthetic values - and
///    normalised by the real normaliser,
///  * the **UI** is built from real Flutter widgets and captured by the
///    real [UiTreeInspector], including its retention policy,
///  * the **verdict** is the real [FigmaStructureValidator].
///
/// Nothing is stubbed between them. What is arranged is the *defect*:
/// each case changes exactly one property of one widget and asserts what
/// the platform says about it.
///
/// The control case has to pass, or none of the rest means anything - a
/// comparison that fails everything catches every defect and is useless.
///
/// The widget tree lays elements out by absolute position at the design's
/// own coordinates. That is not how the application is written and is not
/// meant to be: this file is about whether each defect class is *caught*,
/// not about whether an application matches its design. A real
/// application is measured by `testsmith run`, on a device.
const double _designWidth = 402;
const double _designHeight = 874;

/// The mapping for the `Login` frame, in the form `figma pull` writes.
const String _mappingYaml = '''
screen: /login
nodes:
  "909:16": login.card
  "909:18": login.welcome_title
  "909:19": login.welcome_subtitle
  "909:127": login.continue_button
  "909:129": login.divider_label
  "909:133": login.google_button
  "909:145": login.skip_button
''';

/// The real captured response. Single source of truth: the same file
/// the Figma component's own tests (test/figma/) read, rather than a
/// second copy that could drift from it.
const String _fixturePath = 'test/figma/fixtures/login_node.json';

FigmaScreenSpec _spec() => const FigmaNormaliser().normalise(
  jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, Object?>,
  nodeId: '909:1',
  screen: '/login',
  mapping: FigmaNodeMapping.parse(_mappingYaml, source: 'inline'),
);

/// What the design says, read out of the spec rather than retyped.
///
/// A literal here would be a number copied from Figma into a test, which
/// is the thing this milestone is not allowed to do.
final FigmaScreenSpec _design = _spec();

FigmaElement _element(String semanticId) => _design.bySemanticId(semanticId)!;

/// One deliberate change to the correct implementation.
class Defect {
  const Defect({
    this.dx = 0,
    this.dy = 0,
    this.dWidth = 0,
    this.dHeight = 0,
    this.colour,
    this.fontSize,
    this.fontWeight,
    this.cornerRadius,
    this.opacity,
    this.omit = false,
    this.duplicateId,
    this.detachFromCard = false,
    this.extraElement = false,
  });

  final double dx;
  final double dy;
  final double dWidth;
  final double dHeight;
  final Color? colour;
  final double? fontSize;
  final FontWeight? fontWeight;
  final double? cornerRadius;
  final double? opacity;

  /// Which element the change applies to is given per case; these say
  /// what kind of change it is.
  final bool omit;
  final String? duplicateId;
  final bool detachFromCard;
  final bool extraElement;
}

const Defect _none = Defect();

/// The Login card, implemented to its design, with one seeded defect.
class _LoginUnderTest extends StatelessWidget {
  const _LoginUnderTest({this.target, this.defect = _none});

  /// The semantic id the defect applies to.
  final String? target;
  final Defect defect;

  Defect _for(String semanticId) => semanticId == target ? defect : _none;

  /// A design element's frame-relative rectangle, with any seeded
  /// geometry change applied.
  Rect _rectOf(String semanticId, {Rect? within}) {
    final r = _element(semanticId).rect;
    final d = _for(semanticId);
    final origin = within ?? Rect.zero;
    return Rect.fromLTWH(
      r.x - origin.left + d.dx,
      r.y - origin.top + d.dy,
      r.width + d.dWidth,
      r.height + d.dHeight,
    );
  }

  Widget _box(String semanticId, {required Rect within, Widget? child}) {
    final element = _element(semanticId);
    final d = _for(semanticId);
    final rect = _rectOf(semanticId, within: within);
    final radius = d.cornerRadius ?? element.cornerRadius;
    final fill = _colourOf(element.fill);

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius == null ? null : BorderRadius.circular(radius),
      ),
      child: child ?? const SizedBox.expand(),
    );

    if (d.opacity != null) {
      content = Opacity(opacity: d.opacity!, child: content);
    }

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: TestId(id: d.duplicateId ?? semanticId, child: content),
    );
  }

  Widget _text(String semanticId, {required Rect within}) {
    final element = _element(semanticId);
    final d = _for(semanticId);
    final typography = element.typography!;
    final rect = _rectOf(semanticId, within: within);

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: TestId(
        id: d.duplicateId ?? semanticId,
        child: Text(
          element.text!,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontSize: d.fontSize ?? typography.fontSize,
            fontWeight:
                d.fontWeight ??
                FontWeight.values.firstWhere(
                  (w) => w.value == typography.fontWeight,
                  orElse: () => FontWeight.w400,
                ),
            color: d.colour ?? _colourOf(element.fill),
          ),
        ),
      ),
    );
  }

  static Color? _colourOf(String? hex) {
    if (hex == null) return null;
    final value = hex.replaceFirst('#', '');
    final rgb = int.parse(value.substring(0, 6), radix: 16);
    final alpha = int.parse(value.substring(6, 8), radix: 16);
    return Color((alpha << 24) | rgb);
  }

  @override
  Widget build(BuildContext context) {
    final card = _element('login.card').rect;
    final cardRect = Rect.fromLTWH(card.x, card.y, card.width, card.height);

    final inCard = <Widget>[
      if (!(target == 'login.welcome_title' && defect.detachFromCard))
        _text('login.welcome_title', within: cardRect),
      _text('login.welcome_subtitle', within: cardRect),
      _box('login.continue_button', within: cardRect),
      _box('login.divider_label', within: cardRect),
      if (!(target == 'login.google_button' && defect.omit))
        _box('login.google_button', within: cardRect),
      if (target == 'login.google_button' && defect.duplicateId != null)
        _box('login.google_button', within: cardRect),
    ];

    return Stack(
      children: <Widget>[
        _box(
          'login.card',
          within: Rect.zero,
          child: Stack(children: inCard),
        ),
        _box('login.skip_button', within: Rect.zero),

        // The re-parented element: same geometry, outside the card.
        if (target == 'login.welcome_title' && defect.detachFromCard)
          _text('login.welcome_title', within: Rect.zero),

        // An element the design never drew.
        if (defect.extraElement)
          Positioned(
            left: 20,
            top: 700,
            width: 100,
            height: 20,
            child: TestId(
              id: 'login.debug_banner',
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xFFFF0000)),
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}

Future<List<ValidationResult>> _judge(
  WidgetTester tester, {
  String? target,
  Defect defect = _none,
  FigmaTolerances tolerances = FigmaTolerances.defaults,
}) async {
  // The *view*, not just the MediaQuery. The inspector reads the
  // viewport off `RenderView`, which in a widget test defaults to
  // 800x600 no matter what MediaQuery claims - and the design would then
  // be projected by 800/402, reporting every element as twice its size.
  tester.view
    ..physicalSize = const Size(_designWidth, _designHeight)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    const MediaQuery(
      data: MediaQueryData(size: Size(_designWidth, _designHeight)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(_designWidth, _designHeight)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: _LoginUnderTest(target: target, defect: defect),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final snapshot = const UiTreeInspector().capture(
    root: tester.binding.rootElement!,
    screenId: '/login',
    devicePixelRatio: 1,
  );

  final session = ScreenSession(
    screenId: '/login',
    enteredAt: DateTime.utc(2026, 9, 13),
  )..uiSnapshot = snapshot;

  return const FigmaStructureValidator().validate(
    ValidationContext(
      session: session,
      figmaSpec: _design,
      figmaTolerances: tolerances,
    ),
  );
}

Iterable<ValidationResult> _blocking(List<ValidationResult> results) =>
    results.where((r) => r.blocksPass);

ValidationResult _only(
  List<ValidationResult> results,
  String validatorId,
) => results.firstWhere(
  (r) => r.validatorId == validatorId && r.blocksPass,
  orElse: () => throw StateError(
    'no blocking "$validatorId" result. Got: '
    '${_blocking(results).map((r) => '${r.validatorId}/${r.status.wire}').join(', ')}',
  ),
);

/// Writes the matrix this file proves, so the evidence is produced by the
/// run rather than typed from memory into a document.
class _Matrix {
  final List<List<String>> rows = [];

  void add(List<String> row) => rows.add(row);

  void write() {
    // Run from the package directory; the doc belongs to the repository.
    final file = File('../../docs/evidence/figma_flutter_defect_matrix.md');
    file.parent.createSync(recursive: true);

    const columns = [
      'Seeded Flutter-side defect',
      'Element',
      'Validator',
      'Status',
      'What the report says',
    ];

    final buffer = StringBuffer()
      ..writeln('# Figma defect matrix - Flutter side')
      ..writeln()
      ..writeln(
        'Generated by the test that produced it, on '
        '${DateTime.now().toUtc().toIso8601String().substring(0, 16)}Z. '
        'Do not edit by hand.',
      )
      ..writeln()
      ..writeln(
        'The *design* is correct in every row - it is the `Login` '
        'frame `909:1`, captured from the Figma REST API with its '
        'identifying names, text and ids anonymised. What changes per '
        'row is one property '
        'of one Flutter widget. The UI is captured by the real '
        '`UiTreeInspector` and judged by the real '
        '`FigmaStructureValidator`; nothing between them is stubbed.',
      )
      ..writeln()
      ..writeln('| ${columns.join(' | ')} |')
      ..writeln('|${columns.map((_) => '---').join('|')}|');

    for (final row in rows) {
      buffer.writeln('| ${row.map(_cell).join(' | ')} |');
    }
    file.writeAsStringSync(buffer.toString());
  }

  /// A pipe would start a new column and a newline a new row.
  static String _cell(String value) =>
      value.replaceAll('|', '/').split('\n').join(' ');
}

final _matrix = _Matrix();

/// Asserts the outcome and records the row.
ValidationResult _record(
  String defect,
  List<ValidationResult> results,
  String validatorId, {
  required ValidationStatus expected,
}) {
  final result = results.firstWhere(
    (r) => r.validatorId == validatorId && r.blocksPass,
    orElse: () => throw StateError(
      'no blocking "$validatorId" result. Got: '
      '${_blocking(results).map((r) => '${r.validatorId}/${r.status.wire}').join(', ')}',
    ),
  );
  expect(result.status, expected);
  _matrix.add([
    defect,
    result.elementId ?? '(screen)',
    validatorId,
    result.status.wire.toUpperCase(),
    result.message,
  ]);
  return result;
}

void main() {
  tearDownAll(_matrix.write);

  group('the control', () {
    testWidgets('an implementation built to the design passes', (tester) async {
      final results = await _judge(tester);

      expect(
        _blocking(results),
        isEmpty,
        reason: _blocking(results).map((r) => r.message).join('\n'),
      );
    });

    testWidgets('and the coverage it reports is honest about its scope', (
      tester,
    ) async {
      final facts = (await _judge(
        tester,
      )).firstWhere((r) => r.validatorId == 'figma-coverage').facts;

      // The real frame: 181 nodes, 90 of them comparable, 7 mapped.
      expect(facts['totalNodes'], 181);
      expect(facts['comparableNodes'], 90);
      expect(facts['mappedNodes'], 7);
      expect(facts['comparedNodes'], 7);
      expect(facts['unmappedNodes'], 83);
      expect(facts['verdictScope'], 'mapped elements only');
    });
  });

  group('seeded Flutter-side defects', () {
    testWidgets('1. wrong width', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.continue_button',
        defect: const Defect(dWidth: -40),
      );

      final result = _record(
        'wrong width',
        results,
        'figma-geometry',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.elementId, 'login.continue_button');
      expect(result.message, contains('width'));
    });

    testWidgets('2. wrong height', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.continue_button',
        defect: const Defect(dHeight: 18),
      );

      final result = _record(
        'wrong height',
        results,
        'figma-geometry',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('height'));
    });

    testWidgets('3. wrong position', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.continue_button',
        defect: const Defect(dx: 24),
      );

      final result = _record(
        'wrong position',
        results,
        'figma-geometry',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      // The message names the quantity that disagrees - the inset from
      // the anchor the design declares - rather than a raw coordinate,
      // which on its own says nothing about what is wrong.
      expect(result.message, contains('horizontal leading inset'));
    });

    testWidgets('4. wrong colour', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.welcome_title',
        defect: const Defect(colour: Color(0xFFC2185B)),
      );

      final result = _record(
        'wrong colour',
        results,
        'figma-colour',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('#c2185b'));
    });

    testWidgets('5. wrong font size', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.welcome_title',
        defect: const Defect(fontSize: 14),
      );

      final result = _record(
        'wrong font size',
        results,
        'figma-typography',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('font size'));
    });

    testWidgets('6. wrong font weight', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.welcome_title',
        defect: const Defect(fontWeight: FontWeight.w300),
      );

      final result = _record(
        'wrong font weight',
        results,
        'figma-typography',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('font weight'));
    });

    testWidgets('7. missing node', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.google_button',
        defect: const Defect(omit: true),
      );

      final result = _record(
        'missing node',
        results,
        'figma-structure',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('is missing from the Flutter UI'));
    });

    testWidgets('8. unexpected node', (tester) async {
      final results = await _judge(
        tester,
        defect: const Defect(extraElement: true),
        // Off by default: a screen legitimately carries elements no
        // designer drew. Asked for explicitly here.
        tolerances: const FigmaTolerances(reportUnexpected: true),
      );

      final result = _record(
        'unexpected node',
        results,
        'figma-unexpected',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('login.debug_banner'));
    });

    testWidgets('9. hierarchy mismatch', (tester) async {
      // Same id, same geometry, same style - moved out of the card the
      // design puts it in. Geometry alone cannot see this.
      final results = await _judge(
        tester,
        target: 'login.welcome_title',
        defect: const Defect(detachFromCard: true),
      );

      final result = _record(
        'hierarchy mismatch',
        results,
        'figma-hierarchy',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('login.card'));
      expect(
        _blocking(results).where((r) => r.validatorId == 'figma-geometry'),
        isEmpty,
        reason: 'geometry is unchanged; only the nesting moved',
      );
    });

    testWidgets('10. ambiguous identity is an ERROR, not a guess', (
      tester,
    ) async {
      final results = await _judge(
        tester,
        target: 'login.google_button',
        defect: const Defect(duplicateId: 'login.google_button'),
      );

      final result = _record(
        'ambiguous identity (duplicate test id)',
        results,
        'figma-identity',
        expected: ValidationStatus.error,
      );

      expect(result.status, ValidationStatus.error);
      expect(result.status, isNot(ValidationStatus.fail));
      expect(result.message, contains('cannot be established'));
    });

    testWidgets('11. wrong corner radius', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.skip_button',
        defect: const Defect(cornerRadius: 4),
      );

      final result = _record(
        'wrong corner radius',
        results,
        'figma-radius',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('corner radius'));
    });

    testWidgets('12. wrong opacity', (tester) async {
      // The design draws the card fully opaque; this one is faded.
      final results = await _judge(
        tester,
        target: 'login.card',
        defect: const Defect(opacity: 0.5),
      );

      // Nothing is compared, because the design declares no opacity for
      // this node - and the platform says so rather than inventing a
      // default to compare against.
      expect(results.where((r) => r.validatorId == 'figma-opacity'), isEmpty);
    });

    testWidgets('13. wrong gap between two elements the design spaces', (
      tester,
    ) async {
      final results = await _judge(
        tester,
        target: 'login.google_button',
        defect: const Defect(dy: 24),
      );

      final result = _record(
        'wrong gap between two adjacent elements',
        results,
        'figma-spacing',
        expected: ValidationStatus.fail,
      );

      expect(result.status, ValidationStatus.fail);
      expect(result.message, contains('gap between'));
    });
  });

  group('tolerance is explicit', () {
    testWidgets('a drift inside the tolerance passes', (tester) async {
      final results = await _judge(
        tester,
        target: 'login.continue_button',
        defect: const Defect(dx: 3),
      );

      expect(
        _blocking(results),
        isEmpty,
        reason: _blocking(results).map((r) => r.message).join('\n'),
      );
    });

    testWidgets('the same drift fails once the tolerance is tightened', (
      tester,
    ) async {
      final results = await _judge(
        tester,
        target: 'login.continue_button',
        defect: const Defect(dx: 3),
        tolerances: const FigmaTolerances(positionPx: 1),
      );

      expect(_only(results, 'figma-geometry').status, ValidationStatus.fail);
    });
  });
}
