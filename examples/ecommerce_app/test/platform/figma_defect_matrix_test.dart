import 'dart:convert';
import 'dart:io';

import 'package:ecommerce_app/api/models.dart';
import 'package:ecommerce_app/product_details_screen.dart'
    show ProductDetailsScreen;
import 'package:ecommerce_app/screens/checkout_screen.dart';
import 'package:flutter_testsmith/figma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_testsmith/engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import 'harness.dart';

/// Phase 12, brief item 4 - Figma validation, stressed.
///
/// The screen is real and correct; the **design** is perturbed, one
/// property at a time. That is the direction a design defect actually
/// arrives from: a designer changes a frame and the application has not
/// caught up, and what a team needs to know is exactly which property
/// disagrees.
///
/// Every row asserts the specific validator id, because "the design
/// check failed" is not actionable and `figma-typography` is.
///
/// This is **structural** validation throughout. No screenshot is
/// compared with a Figma export anywhere here, and none could be: see
/// risk R7 and ADR-0008.

final matrix = MatrixRecorder(
  'Figma structural defect matrix',
  'docs/evidence/figma_defect_matrix.md',
  const [
    'Defect seeded in the design',
    'Screen',
    'Element',
    'Validator',
    'Status',
    'What the report says',
  ],
);

/// The committed normalised design for a screen.
FigmaScreenSpec designFor(String name) {
  for (final candidate in ['figma/$name.json', 'examples/ecommerce_app/figma/$name.json']) {
    final file = File(candidate);
    if (file.existsSync()) {
      return FigmaScreenSpec.fromJson(
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>(),
      );
    }
  }
  fail('cannot find figma/$name.json from ${Directory.current.path}');
}

/// A copy of [spec] with one element changed.
///
/// Round-tripped through JSON rather than given a `copyWith`: the
/// perturbation then goes through exactly the parser a pulled design
/// goes through, so a defect this matrix seeds is one a real file could
/// express.
FigmaScreenSpec perturb(
  FigmaScreenSpec spec,
  String semanticId,
  Map<String, Object?> Function(Map<String, Object?>) change,
) {
  final json = spec.toJson();
  final elements = (json['elements']! as List).cast<Map<String, Object?>>();

  var found = false;
  final updated = [
    for (final element in elements)
      if (element['semanticId'] == semanticId)
        (() {
          found = true;
          return change(Map<String, Object?>.from(element));
        })()
      else
        element,
  ];
  if (!found) fail('the design has no element mapped to "$semanticId"');

  return FigmaScreenSpec.fromJson({...json, 'elements': updated});
}

/// A copy of [spec] with an extra mapped element the screen cannot have.
FigmaScreenSpec withExtraElement(FigmaScreenSpec spec, String semanticId) {
  final json = spec.toJson();
  return FigmaScreenSpec.fromJson({
    ...json,
    'elements': [
      ...(json['elements']! as List),
      {
        'nodeId': '9999:0001',
        'figmaName': 'Badge / new',
        'semanticId': semanticId,
        'type': 'TEXT',
        'rect': {'x': 20.0, 'y': 500.0, 'width': 60.0, 'height': 16.0},
        'text': 'New',
      },
    ],
  });
}

/// Runs the design comparison over a captured tree.
List<ValidationResult> compare(
  UiSnapshot snapshot,
  FigmaScreenSpec spec, {
  FigmaTolerances tolerances = FigmaTolerances.defaults,
}) {
  final session = ScreenSession(
    screenId: spec.screen,
    enteredAt: DateTime.now().toUtc(),
  )..uiSnapshot = snapshot;

  return const FigmaStructureValidator().validate(
    ValidationContext(
      session: session,
      figmaSpec: spec,
      figmaTolerances: tolerances,
    ),
  );
}

/// The result from [validatorId] about [elementId], or null.
ValidationResult? find(
  List<ValidationResult> results,
  String validatorId, [
  String? elementId,
]) {
  for (final result in results) {
    if (result.validatorId != validatorId) continue;
    if (elementId != null && result.elementId != elementId) continue;
    return result;
  }
  return null;
}

/// Records a row and returns the result.
ValidationResult expectFailure(
  List<ValidationResult> results, {
  required String label,
  required String screen,
  required String validatorId,
  String? elementId,
}) {
  final result = find(results, validatorId, elementId);
  expect(
    result,
    isNotNull,
    reason: 'no $validatorId result for ${elementId ?? 'the screen'}. Got:\n'
        '${results.map((r) => '  $r').join('\n')}',
  );
  expect(result!.status, ValidationStatus.fail, reason: result.message);

  matrix.add([
    label,
    screen,
    elementId ?? '(screen)',
    validatorId,
    'FAIL',
    result.message,
  ]);
  return result;
}

void main() {
  setUp(resetDefects);
  tearDownAll(() => matrix.write(
        preamble: 'The application is correct in every row; the design '
            'is what was changed. Structural comparison only - no '
            'screenshot is compared with a Figma export anywhere in this '
            'platform, and the acceptance report does not claim it is.',
      ));

  group('/checkout - a design frame the same shape as the viewport', () {
    late UiSnapshot snapshot;
    late FigmaScreenSpec design;

    Future<void> prepare(WidgetTester tester) async {
      design = designFor('checkout');
      snapshot = await pumpAndCaptureWith(
        tester,
        const CheckoutScreen(),
        screenId: '/checkout',
      );
    }

    testWidgets('the unchanged design passes every check', (tester) async {
      await prepare(tester);
      final results = compare(snapshot, design);

      final failures = results.where((r) => r.status == ValidationStatus.fail);
      expect(
        failures,
        isEmpty,
        reason: 'a correct screen must pass, or every row below measures '
            'noise:\n${failures.map((f) => '  $f').join('\n')}',
      );

      // And it really did compare vertical position: the frame and the
      // viewport are the same shape, so nothing was honestly skipped.
      expect(find(results, 'figma-geometry', 'checkout.total')!.status,
          ValidationStatus.pass);

      matrix.add([
        '(none - control)',
        '/checkout',
        'all 7 mapped',
        'figma-structure, -type, -geometry, -typography, -colour, -order',
        'PASS',
        '${results.where((r) => r.status == ValidationStatus.pass).length} '
            'checks passed, 0 failed',
      ]);
    });

    testWidgets('missing element', (tester) async {
      await prepare(tester);
      // The design gains a badge the application does not render.
      final results = compare(
        snapshot,
        withExtraElement(design, 'checkout.promo_badge'),
      );

      final result = expectFailure(
        results,
        label: 'missing element',
        screen: '/checkout',
        validatorId: 'figma-structure',
        elementId: 'checkout.promo_badge',
      );
      expect(result.message, contains('missing from the Flutter UI'));
      // And it lists what is there, so the reader can see the typo.
      expect(result.message, contains('checkout.total'));
    });

    testWidgets('wrong position', (tester) async {
      await prepare(tester);
      final results = compare(
        snapshot,
        perturb(design, 'checkout.total', (e) {
          final rect = Map<String, Object?>.from(e['rect']! as Map);
          return {...e, 'rect': {...rect, 'x': (rect['x']! as num) - 24}};
        }),
      );

      final result = expectFailure(
        results,
        label: 'wrong position (x out by 24)',
        screen: '/checkout',
        validatorId: 'figma-geometry',
        elementId: 'checkout.total',
      );
      expect(result.message, contains('horizontal leading inset'));
      expect(result.message, contains('tolerance'));
    });

    testWidgets('wrong dimensions', (tester) async {
      await prepare(tester);
      final results = compare(
        snapshot,
        perturb(design, 'checkout.place_order', (e) {
          final rect = Map<String, Object?>.from(e['rect']! as Map);
          return {
            ...e,
            'rect': {...rect, 'height': (rect['height']! as num) + 18},
          };
        }),
      );

      final result = expectFailure(
        results,
        label: 'wrong dimensions (height out by 18)',
        screen: '/checkout',
        validatorId: 'figma-geometry',
        elementId: 'checkout.place_order',
      );
      expect(result.message, contains('height is'));
    });

    testWidgets('incorrect spacing', (tester) async {
      await prepare(tester);
      // A spacing defect is not its own check. A gap that grew by 24
      // puts every element below it 24 out of place, which is what the
      // geometry check measures - and naming it "spacing" would imply a
      // comparison the platform does not make.
      final results = compare(
        snapshot,
        perturb(design, 'checkout.delivery_fee', (e) {
          final rect = Map<String, Object?>.from(e['rect']! as Map);
          return {...e, 'rect': {...rect, 'y': (rect['y']! as num) + 24}};
        }),
      );

      final result = expectFailure(
        results,
        label: 'incorrect spacing (gap 24 too large; reported as position)',
        screen: '/checkout',
        validatorId: 'figma-geometry',
        elementId: 'checkout.delivery_fee',
      );
      expect(result.message, contains('vertical leading inset'));
    });

    testWidgets('wrong typography', (tester) async {
      await prepare(tester);
      final results = compare(
        snapshot,
        perturb(design, 'checkout.total', (e) {
          final type = Map<String, Object?>.from(e['typography']! as Map);
          return {
            ...e,
            'typography': {...type, 'fontSize': 22.0, 'fontWeight': 400},
          };
        }),
      );

      final result = expectFailure(
        results,
        label: 'wrong typography (size and weight)',
        screen: '/checkout',
        validatorId: 'figma-typography',
        elementId: 'checkout.total',
      );
      expect(result.message, contains('font size'));
      expect(result.message, contains('font weight'));
    });

    testWidgets('wrong colour', (tester) async {
      await prepare(tester);
      final results = compare(
        snapshot,
        perturb(design, 'checkout.total', (e) => {...e, 'fill': '#c2185bff'}),
      );

      final result = expectFailure(
        results,
        label: 'wrong colour',
        screen: '/checkout',
        validatorId: 'figma-colour',
        elementId: 'checkout.total',
      );
      expect(result.message, contains('#c2185bff'));
      expect(result.message, contains('channel difference'));
    });

    testWidgets('incorrect text, once copy is compared at all',
        (tester) async {
      await prepare(tester);
      // Off by default, because a design holds placeholder copy while
      // the app shows live data. Opted into here, which is what a screen
      // with static copy would do.
      final results = compare(
        snapshot,
        perturb(design, 'checkout.total', (e) => {...e, 'text': 'Rs 9,999'}),
        tolerances: const FigmaTolerances(text: TextComparisonMode.strict),
      );

      final result = expectFailure(
        results,
        label: 'incorrect text (text: strict)',
        screen: '/checkout',
        validatorId: 'figma-text',
        elementId: 'checkout.total',
      );
      expect(result.message, contains('Rs 9,999'));
    });

    testWidgets('design copy is ignored by default', (tester) async {
      await prepare(tester);
      // The same perturbation, without opting in. It must not fail: the
      // design says "Rs 0" and the app shows what the API returned, and
      // failing every screen that works is how a check gets disabled.
      final results = compare(
        snapshot,
        perturb(design, 'checkout.total', (e) => {...e, 'text': 'Rs 9,999'}),
      );

      expect(find(results, 'figma-text', 'checkout.total'), isNull);
      expect(
        results.where((r) => r.status == ValidationStatus.fail),
        isEmpty,
      );

      matrix.add([
        'incorrect text, default tolerances',
        '/checkout',
        'checkout.total',
        'figma-text',
        'NOT RUN',
        'design copy is placeholder by default; opt in with text: strict',
      ]);
    });

    testWidgets('wrong order', (tester) async {
      await prepare(tester);
      // The design puts the delivery line above the total; the screen
      // puts it below. Ordering survives the scaling problems that make
      // absolute vertical comparison unreliable.
      final results = compare(
        snapshot,
        perturb(design, 'checkout.delivery_fee', (e) {
          final rect = Map<String, Object?>.from(e['rect']! as Map);
          return {...e, 'rect': {...rect, 'y': 100.0}};
        }),
      );

      final result = expectFailure(
        results,
        label: 'wrong order (two elements swapped)',
        screen: '/checkout',
        validatorId: 'figma-order',
      );
      expect(result.message, contains('top-to-bottom order'));
    });

    testWidgets('a stale mapping is an error, not an application defect',
        (tester) async {
      await prepare(tester);
      final json = design.toJson();
      final results = compare(
        snapshot,
        FigmaScreenSpec.fromJson({
          ...json,
          'unmatchedMappings': ['2100:9999'],
        }),
      );

      final result = find(results, 'figma-mapping');
      expect(result, isNotNull);
      // Error, not fail: the tool is misconfigured, the app is fine. It
      // still blocks the pass, because nothing was shown to be correct.
      expect(result!.status, ValidationStatus.error);

      matrix.add([
        'stale node mapping',
        '/checkout',
        '(tool configuration)',
        'figma-mapping',
        'ERROR',
        result.message,
      ]);
    });
  });

  group('/product/details - a tall frame against a phone viewport', () {
    late UiSnapshot snapshot;
    late FigmaScreenSpec design;

    Future<void> prepare(WidgetTester tester) async {
      design = designFor('product_details');
      final body = fixtureBody('default', 'GET', '/products/123');
      snapshot = await pumpAndCapture(
        tester,
        ProductDetailsScreen(fetchProduct: () async => Product.fromJson(body)),
        screenId: '/product/details',
      );
    }

    testWidgets('vertical position is skipped, not failed, when the frame '
        'is a different shape', (tester) async {
      await prepare(tester);
      final results = compare(snapshot, design);

      final skip = results.firstWhere(
        (r) =>
            r.validatorId == 'figma-geometry' &&
            r.status == ValidationStatus.skip,
      );
      expect(skip.message, contains('vertical positions were not compared'));
      expect(skip.message, contains('aspect difference'));

      matrix.add([
        '(none - control)',
        '/product/details',
        '(screen)',
        'figma-geometry',
        'SKIP',
        skip.message,
      ]);
    });

    testWidgets('wrong element type - a TEXT node that paints an image',
        (tester) async {
      await prepare(tester);
      final results = compare(
        snapshot,
        perturb(design, 'product.image', (e) => {...e, 'type': 'TEXT'}),
      );

      final result = expectFailure(
        results,
        label: 'wrong element type (IMAGE declared TEXT)',
        screen: '/product/details',
        validatorId: 'figma-type',
        elementId: 'product.image',
      );
      expect(result.message, contains('renders no text'));
    });

    testWidgets('an IMAGE node on a widget that might paint one is skipped, '
        'not guessed', (tester) async {
      await prepare(tester);
      // A Container with a DecorationImage is a legitimate way to render
      // an IMAGE node, and the widget type alone cannot tell us. Saying
      // so beats inventing a rule nobody agreed to.
      final results = compare(
        snapshot,
        perturb(design, 'product.name', (e) => {...e, 'type': 'IMAGE'}),
      );

      final result = find(results, 'figma-type', 'product.name');
      expect(result!.status, ValidationStatus.skip);
      expect(result.message, contains('Not judged'));

      matrix.add([
        'IMAGE declared over a non-image widget',
        '/product/details',
        'product.name',
        'figma-type',
        'SKIP',
        result.message,
      ]);
    });

    testWidgets('horizontal position is still compared on a tall frame',
        (tester) async {
      await prepare(tester);
      // The honest-skip must not become a blanket excuse: x and size are
      // still checked when y cannot be.
      final results = compare(
        snapshot,
        perturb(design, 'product.name', (e) {
          final rect = Map<String, Object?>.from(e['rect']! as Map);
          return {...e, 'rect': {...rect, 'x': (rect['x']! as num) + 40}};
        }),
      );

      final result = expectFailure(
        results,
        label: 'wrong position on a tall frame (x only)',
        screen: '/product/details',
        validatorId: 'figma-geometry',
        elementId: 'product.name',
      );
      expect(result.message, contains('horizontal leading inset'));
      expect(result.message, isNot(contains('vertical')));
    });

    testWidgets('typography is read from the descendant that paints the text',
        (tester) async {
      await prepare(tester);
      // The id is on the element a person interacts with; the design's
      // TEXT node describes the label inside it.
      final results = compare(
        snapshot,
        perturb(design, 'product.description', (e) {
          final type = Map<String, Object?>.from(e['typography']! as Map);
          return {...e, 'typography': {...type, 'fontWeight': 900}};
        }),
      );

      expectFailure(
        results,
        label: 'wrong typography on a nested label',
        screen: '/product/details',
        validatorId: 'figma-typography',
        elementId: 'product.description',
      );
    });
  });
}
