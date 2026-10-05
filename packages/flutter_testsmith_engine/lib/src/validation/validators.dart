import 'package:flutter_testsmith_figma/flutter_testsmith_figma.dart';
import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../session/screen_session.dart';
import 'api_acquisition.dart';
import 'figma_tolerances.dart';
import 'mappings.dart';
import 'response_source.dart';
import 'transformations.dart';
import 'validation_dimension.dart';
import 'validation_result.dart';

/// Everything a validator is allowed to look at.
@immutable
class ValidationContext {
  ValidationContext({
    required this.session,
    this.mappings,
    this.figmaSpec,
    this.acquired,
    List<ScreenSession>? sessionHistory,
    TransformationRegistry? transformations,
    FigmaTolerances? figmaTolerances,
  })  : sessionHistory = sessionHistory ?? const [],
        transformations = transformations ?? TransformationRegistry.defaults(),
        figmaTolerances = figmaTolerances ?? FigmaTolerances.defaults;

  final ScreenSession session;

  /// Every screen session in the run, oldest first.
  ///
  /// The platform used to model one screen as owning one set of API
  /// exchanges. That is not how applications work: a screen frequently
  /// renders data fetched during splash, on another tab, or by a cache
  /// warmed minutes earlier. Provenance is therefore resolved against
  /// the whole session, and **only when a mappings file explicitly asks
  /// for it** - see [ResponseSource].
  ///
  /// Empty means "no history was supplied", and every screen behaves
  /// exactly as it did before this existed.
  final List<ScreenSession> sessionHistory;
  final MappingsFile? mappings;
  final TransformationRegistry transformations;

  /// The normalised design for this screen, when one is configured.
  ///
  /// Null is not a failure: most screens have no design bound, and a
  /// missing design makes Figma validation skip, never fail.
  final FigmaScreenSpec? figmaSpec;

  final FigmaTolerances figmaTolerances;

  /// How this screen's response was obtained, when the runner resolved
  /// it ahead of validation.
  ///
  /// Null keeps the pre-E-06 behaviour exactly: [response] falls back to
  /// reading the captured exchanges itself.
  final ApiAcquisition? acquired;

  UiSnapshot? get snapshot => session.uiSnapshot;

  /// The response this screen's validation is about.
  ///
  /// The exchange the mappings file **names**, when it names one.
  ///
  /// `api: GET /products/123` has been in the mappings format since
  /// Phase 4 and was parsed and then ignored: this returned whichever
  /// completed exchange happened to be first. Every screen in the
  /// platform's own example makes exactly one call, so it never
  /// mattered.
  ///
  /// On a real application it matters immediately. Measured: the first
  /// exchange on a profile screen was a third-party **geocoding** call
  /// to a different host, and the profile's mappings were compared
  /// against it - reporting "the response has no field data.firstName"
  /// about a maps reply.
  ///
  /// With no `api:` declared the old behaviour stands, because a screen
  /// that makes one call should not have to say so.
  /// Where this screen's data came from, when it declares it.
  ResponseResolution? get declaredSource {
    final source = mappings?.usesResponseFrom;
    if (source == null) return null;

    return const ResponseResolver().resolve(
      source: source,
      // The current screen is included: a screen that declares its
      // provenance and *also* fetches its own data is not a special
      // case.
      history: sessionHistory.isEmpty ? [session] : sessionHistory,
      renderedScreenEnteredAt: session.enteredAt,
    );
  }

  ApiResponsePayload? get response {
    // The runner's own resolution wins when it made one: it already
    // preferred the capture and only fetched where the capture had
    // nothing to give.
    final resolved = acquired;
    if (resolved != null) {
      return switch (resolved) {
        AcquiredFromCapture(:final payload) => payload,
        AcquiredFromFetch(:final payload) => payload,
        AcquisitionUnavailable() || AcquisitionAmbiguous() => null,
      };
    }

    final resolution = declaredSource;
    if (resolution != null) {
      return resolution is ResponseResolved ? resolution.response.payload : null;
    }

    final declared = endpoint;
    if (declared == null) {
      for (final exchange in session.exchanges) {
        final payload = exchange.response;
        if (payload != null) return payload;
      }
      return null;
    }

    for (final exchange in session.exchanges) {
      final payload = exchange.response;
      if (payload == null) continue;
      if (declared.matches(exchange.request.method, exchange.request.path)) {
        return payload;
      }
    }
    return null;
  }

  /// The endpoint the mappings file names, if it names a valid one.
  ApiEndpoint? get endpoint => ApiEndpoint.tryParse(mappings?.api);

  /// Every completed exchange on this screen, for a diagnostic.
  List<String> get capturedEndpoints => [
        for (final exchange in session.exchanges)
          if (exchange.response != null)
            '${exchange.request.method} ${exchange.request.path}',
      ];
}

/// One deterministic check over a screen.
abstract interface class ScreenValidator {
  String get id;

  /// The source of truth this validator measures against.
  ///
  /// Stamped onto every result it returns that does not name its own.
  ValidationDimension get dimension;

  List<ValidationResult> validate(ValidationContext context);
}

/// Runs a validator and stamps its dimension over the results.
///
/// The one place a dimension is applied by default, so a new validator
/// cannot forget - and so no report-time table has to guess a dimension
/// from a validator's name.
List<ValidationResult> runValidator(
  ScreenValidator validator,
  ValidationContext context,
) =>
    [
      for (final result in validator.validate(context))
        result.inDimension(validator.dimension),
    ];

/// The outcome of reading a property off a node.
///
/// Sealed rather than a nullable value, because "there is no such text"
/// and "there are two and I will not choose" are different facts. The
/// second must reach a report as an **error**; collapsing them to null
/// made a correct screen look broken.
@immutable
sealed class PropertyRead {
  const PropertyRead();
}

final class PropertyValue extends PropertyRead {
  const PropertyValue(this.value);

  final Object? value;
}

/// Several descendants answer, and they disagree.
final class PropertyAmbiguous extends PropertyRead {
  const PropertyAmbiguous(this.property, this.candidates);

  final String property;
  final List<String> candidates;

  String get reason =>
      'reading "$property" is ambiguous: ${candidates.length} descendants '
      'answer, and they disagree - ${candidates.map((c) => '"$c"').join(', ')}. '
      'Put the id on the element that carries the value, or assert on a '
      'descendant directly.';
}

/// Reads a named property off a UI node.
///
/// `text`, `value` and `enabled` fall through to descendants when the
/// node itself has none. A semantic id belongs on the thing a person
/// means - `TestId(id: 'nav.orders', child: InkWell(... Text('Orders')))`
/// is the ordinary shape - so `target.text` means **the effective
/// user-visible text of the subtree**, not the raw field of one node.
///
/// Everything else reads the node and only the node. `visible`, `label`,
/// `type` and the property bag describe one element, and borrowing them
/// from a child would be a different claim.
PropertyRead readPropertyOf(UiNode node, String property) =>
    switch (property) {
      'text' || 'value' => _effectiveText(node),
      'enabled' => _effectiveEnabled(node),
      'visible' => PropertyValue(node.visible),
      'label' => PropertyValue(node.label),
      'type' => PropertyValue(node.type),
      _ => PropertyValue(node.properties[property]),
    };

/// The value, or null when there is none or the answer is ambiguous.
///
/// Kept for callers that cannot express an error - a flow step's
/// message, a diagnostic. A validator uses [readPropertyOf] so that an
/// ambiguity is reported as one.
Object? readProperty(UiNode node, String property) =>
    switch (readPropertyOf(node, property)) {
      PropertyValue(:final value) => value,
      PropertyAmbiguous() => null,
    };

/// Whether [text] is an icon rather than words.
///
/// **This is the defect that prompted all of it.** A Flutter `Icon`
/// renders through a `RichText` whose content is a single private-use
/// codepoint - `U+E491` for Material Icons, and the same range for
/// Cupertino and the common icon fonts. Counting that as text made
/// `profile.complete_button` ambiguous between an icon and its label,
/// so `.text` resolved to null on a screen that plainly reads
/// "Complete Your Profile".
///
/// Detected by codepoint rather than by widget type alone, because an
/// icon is also legitimately drawn with `Text(String.fromCharCode(...))`
/// and a font family. Nothing outside the private-use area is affected:
/// no real copy lives there, by definition.
bool _isIconGlyph(String text) {
  final runes = text.trim().runes;
  if (runes.isEmpty) return false;
  return runes.every((rune) =>
      (rune >= 0xE000 && rune <= 0xF8FF) || // Basic Multilingual Plane
      (rune >= 0xF0000 && rune <= 0xFFFFD) || // Supplementary A
      (rune >= 0x100000 && rune <= 0x10FFFD)); // Supplementary B
}

/// Text a person can actually read on this subtree.
///
/// A descendant counts only when all of the following hold. Each
/// exclusion is a case that was measured, not imagined:
///
/// * it renders non-empty text;
/// * it is **visible** - a zero-area or hidden node is not on screen;
/// * it is not an icon glyph, and not inside an `Icon`;
/// * it belongs to the **same route** as the target, so a screen
///   underneath cannot answer for the one in front.
///
/// Candidates that all say the same thing are one answer, not several:
/// a `TextField` and the `EditableText` inside it both report the value.
PropertyRead _effectiveText(UiNode node) {
  final own = node.text;
  if (own != null && own.isNotEmpty) return PropertyValue(own);

  final found = <String>[];
  final route = node.properties['routeIndex'];

  void walk(UiNode current, {required bool insideIcon}) {
    for (final child in current.children) {
      final childRoute = child.properties['routeIndex'];
      if (route is int && childRoute is int && childRoute != route) continue;

      final isIcon = insideIcon || child.type == 'Icon';
      final text = child.text;

      if (!isIcon &&
          child.visible &&
          !child.bounds.isEmpty &&
          text != null &&
          text.isNotEmpty &&
          !_isIconGlyph(text)) {
        found.add(text);
      }

      walk(child, insideIcon: isIcon);
    }
  }

  walk(node, insideIcon: node.type == 'Icon');

  if (found.isEmpty) return const PropertyValue(null);

  final distinct = found.toSet();
  if (distinct.length == 1) return PropertyValue(distinct.single);

  return PropertyAmbiguous('text', distinct.toList());
}

/// The enabled state of the subtree.
///
/// Same shape as [_effectiveText] and for the same reason: the id sits
/// on a wrapper and the `InkWell` two levels down is what knows.
PropertyRead _effectiveEnabled(UiNode node) {
  final own = node.enabled;
  if (own != null) return PropertyValue(own);

  final found = <bool>[];
  final route = node.properties['routeIndex'];

  void walk(UiNode current) {
    for (final child in current.children) {
      final childRoute = child.properties['routeIndex'];
      if (route is int && childRoute is int && childRoute != route) continue;

      final enabled = child.enabled;
      if (enabled != null && child.visible) found.add(enabled);
      walk(child);
    }
  }

  walk(node);

  if (found.isEmpty) return const PropertyValue(null);

  final distinct = found.toSet();
  if (distinct.length == 1) return PropertyValue(distinct.single);

  return PropertyAmbiguous(
    'enabled',
    distinct.map((value) => '$value').toList(),
  );
}

/// Compares mapped API fields against what the UI actually shows.
class ApiToUiValidator implements ScreenValidator {
  const ApiToUiValidator();

  @override
  String get id => 'api-to-ui';

  @override
  ValidationDimension get dimension => ValidationDimension.api;

  @override
  List<ValidationResult> validate(ValidationContext context) {
    final mappings = context.mappings;
    if (mappings == null || mappings.mappings.isEmpty) {
      return [
        ValidationResult.skip(
          validatorId: id,
          message: 'no API-to-UI mappings configured for '
              '${context.session.screenId}',
        ),
      ];
    }

    final snapshot = context.snapshot;
    if (snapshot == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          // The tool could not read the UI, so nothing was compared
          // against the API. Reporting this as an API result would make
          // the API dimension speak for a check that never ran.
          dimension: ValidationDimension.ui,
          message: 'no UI tree was captured for this screen, so nothing '
              'could be compared',
        ),
      ];
    }

    final response = context.response;
    if (response == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          message: _noResponseMessage(context),
        ),
      ];
    }

    return [
      for (final mapping in mappings.mappings)
        _check(context, mapping, snapshot, response),
    ];
  }

  /// Why there was nothing to compare against.
  ///
  /// "No response was captured" and "the response you named never
  /// arrived, but these four did" send someone to completely different
  /// places.
  static String _noResponseMessage(ValidationContext context) {
    // The acquirer's own reason is the most specific one available: it
    // knows whether the capture was absent, ambiguous, or present but
    // the declared fallback could not be used either.
    switch (context.acquired) {
      case AcquisitionUnavailable(:final reason):
        return reason;
      case AcquisitionAmbiguous(:final reason):
        return reason;
      case AcquiredFromCapture():
      case AcquiredFromFetch():
      case null:
        break;
    }

    // A declared provenance explains itself far better than anything
    // this method could infer.
    switch (context.declaredSource) {
      case ResponseUnavailable(:final reason):
        return reason;
      case ResponseAmbiguous(:final reason):
        return reason;
      case ResponseResolved():
      case null:
        break;
    }

    final declared = context.endpoint;
    final captured = context.capturedEndpoints;

    if (declared == null) {
      return 'no API response was captured for this screen, so nothing '
          'could be compared';
    }
    if (captured.isEmpty) {
      return 'the mappings name "$declared" but this screen captured no '
          'completed API exchange at all';
    }
    return 'the mappings name "$declared", which this screen did not '
        'call. It called: ${captured.join(', ')}.';
  }

  ValidationResult _check(
    ValidationContext context,
    Mapping mapping,
    UiSnapshot snapshot,
    ApiResponsePayload response,
  ) {
    final node = snapshot.find(mapping.target);
    if (node == null) {
      return ValidationResult.fail(
        validatorId: id,
        elementId: mapping.target,
        message: 'mapped element "${mapping.target}" is not on the screen. '
            'Present: ${_idsIn(snapshot).join(', ')}',
      );
    }

    final raw = response.readPath(mapping.responsePath);
    if (raw == null) {
      return ValidationResult.fail(
        validatorId: id,
        elementId: mapping.target,
        message: 'the response has no field "${mapping.responsePath}", '
            'which "${mapping.target}" is mapped to',
        expected: mapping.source,
      );
    }

    final Object? transformed;
    try {
      transformed = context.transformations.apply(mapping.transformation, raw);
    } on TransformationFailedException catch (error) {
      // The tool is wrong here, not the application under test.
      return ValidationResult.error(
        validatorId: id,
        elementId: mapping.target,
        message: 'could not apply ${mapping.transformation} to the value '
            'of ${mapping.source}: $error',
      );
    }

    final read = readPropertyOf(node, mapping.property);
    if (read is PropertyAmbiguous) {
      // The tool cannot answer the question, which is not evidence
      // about the application.
      return ValidationResult.error(
        validatorId: id,
        elementId: mapping.target,
        // A duplicate test id is a UI identity defect, not an API one.
        dimension: ValidationDimension.ui,
        message: '${mapping.target}: ${read.reason}',
      );
    }
    final actual = (read as PropertyValue).value;

    // The whole chain, as structured evidence rather than only as prose.
    //
    // The three values are what distinguish a data bug from a formatting
    // bug, and until Phase 12 the raw one existed only inside a sentence
    // - which meant no consumer of result.json could read it, and a
    // report could not put the chain in a column. The message keeps the
    // sentence because a person reading a terminal wants one.
    final source = switch (context.declaredSource) {
      ResponseResolved(:final response) => response,
      _ => null,
    };

    final chain = [
      // Which source this verdict rests on. A reader must never have to
      // guess whether a PASS was measured against the application's own
      // traffic or against a request the runner made.
      ...switch (context.acquired) {
        AcquiredFromCapture(:final endpoint) => [
            const Evidence(kind: 'responseProvenance', reference: 'captured'),
            Evidence(kind: 'responseEndpoint', reference: endpoint),
          ],
        AcquiredFromFetch(:final endpoint, :final fallbackReason) => [
            const Evidence(kind: 'responseProvenance', reference: 'fetched'),
            Evidence(kind: 'responseEndpoint', reference: endpoint),
            Evidence(kind: 'fallbackReason', reference: fallbackReason),
          ],
        _ => const <Evidence>[],
      },
      if (source != null) ...[
        Evidence(kind: 'sourceEndpoint', reference: source.endpoint),
        Evidence(kind: 'sourceScreen', reference: source.capturedOnScreen),
        Evidence(
          kind: 'sourceCapturedAt',
          reference: formatUtcTimestamp(source.capturedAt),
        ),
        Evidence(kind: 'sourceRequestId', reference: source.requestId),
        Evidence(
          kind: 'sourceAgeSeconds',
          reference: '${source.age.inSeconds}',
        ),
        Evidence(
          kind: 'renderedScreen',
          reference: context.session.screenId,
        ),
      ],
      Evidence(kind: 'apiPath', reference: mapping.source),
      Evidence(kind: 'apiValue', reference: '$raw'),
      Evidence(kind: 'transformation', reference: mapping.transformation),
      Evidence(kind: 'transformedValue', reference: '$transformed'),
      Evidence(kind: 'element', reference: mapping.target),
      Evidence(kind: 'property', reference: mapping.property),
      Evidence(kind: 'uiValue', reference: '$actual'),
    ];

    final provenance = source == null ||
            source.capturedOnScreen == context.session.screenId
        ? ''
        : ' (from ${source.endpoint} captured on '
            '"${source.capturedOnScreen}", ${source.age.inSeconds}s earlier)';

    if (_matches(transformed, actual)) {
      return ValidationResult.pass(
        validatorId: id,
        elementId: mapping.target,
        message: '${mapping.source} matches ${mapping.target}.'
            '${mapping.property}$provenance',
        expected: transformed,
        actual: actual,
        evidence: chain,
      );
    }

    return ValidationResult.fail(
      validatorId: id,
      elementId: mapping.target,
      message: '${mapping.target}.${mapping.property} does not match '
          '${mapping.source}$provenance. API returned $raw; '
          '${mapping.transformation} gives "$transformed"; '
          'the UI shows "$actual".',
      expected: transformed,
      actual: actual,
      evidence: chain,
    );
  }

  static bool _matches(Object? expected, Object? actual) {
    if (expected == actual) return true;
    // A number rendered as text is still that number.
    return expected?.toString() == actual?.toString();
  }

  static List<String> _idsIn(UiSnapshot snapshot) =>
      snapshot.root.testIds.toList()..sort();
}

/// Checks that every element a mapping refers to is actually addressable.
class UiPresenceValidator implements ScreenValidator {
  const UiPresenceValidator();

  @override
  String get id => 'ui-presence';

  @override
  ValidationDimension get dimension => ValidationDimension.ui;

  @override
  List<ValidationResult> validate(ValidationContext context) {
    final mappings = context.mappings;
    final snapshot = context.snapshot;

    if (mappings == null || mappings.mappings.isEmpty) {
      return [
        ValidationResult.skip(
          validatorId: id,
          message: 'no mappings configured',
        ),
      ];
    }
    if (snapshot == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          message: 'no UI tree was captured for this screen',
        ),
      ];
    }

    return [
      for (final mapping in mappings.mappings)
        _checkPresence(mapping.target, snapshot),
    ];
  }

  ValidationResult _checkPresence(String target, UiSnapshot snapshot) {
    if (snapshot.duplicateTestIds.contains(target)) {
      return ValidationResult.fail(
        validatorId: id,
        elementId: target,
        message: '"$target" is on more than one element, so any assertion '
            'about it has no single meaning',
      );
    }
    if (snapshot.find(target) == null) {
      return ValidationResult.fail(
        validatorId: id,
        elementId: target,
        message: '"$target" is not on the screen. Present: '
            '${(snapshot.root.testIds.toList()..sort()).join(', ')}',
      );
    }
    return ValidationResult.pass(
      validatorId: id,
      elementId: target,
      message: '"$target" is present',
    );
  }
}

/// Applies the declarative business rules.
class RulesValidator implements ScreenValidator {
  const RulesValidator();

  @override
  String get id => 'rules';

  /// A rule's condition is evaluated against the **API response** -
  /// `Condition.evaluate` takes `response.readPath` and has no access to
  /// the UI snapshot at all - and its expectation is checked on the UI.
  /// A rule is therefore an API-to-UI consistency statement in
  /// conditional form. Read off the implementation, not off the name: if
  /// a condition ever became able to read a UI property, this is the one
  /// place that would have to change with it.
  @override
  ValidationDimension get dimension => ValidationDimension.api;

  @override
  List<ValidationResult> validate(ValidationContext context) {
    final mappings = context.mappings;
    if (mappings == null || mappings.rules.isEmpty) {
      return [
        ValidationResult.skip(
          validatorId: id,
          message: 'no rules configured for ${context.session.screenId}',
        ),
      ];
    }

    final snapshot = context.snapshot;
    final response = context.response;
    // Split rather than a ternary: the two causes belong to different
    // dimensions. "The UI could not be read" is a UI-evidence problem;
    // "the response is missing" is an API one.
    if (snapshot == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          dimension: ValidationDimension.ui,
          message: 'rules need a UI tree, and none was captured',
        ),
      ];
    }
    if (response == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          // No dimension: the validator default (api) is correct here.
          message: 'rules need an API response: '
              '${ApiToUiValidator._noResponseMessage(context)}',
        ),
      ];
    }

    final results = <ValidationResult>[];
    for (final rule in mappings.rules) {
      final condition = Condition.parse(rule.condition);
      if (!condition.evaluate(response.readPath)) {
        results.add(
          ValidationResult.skip(
            validatorId: id,
            message: 'rule "${rule.condition}" does not apply to this '
                'response',
          ),
        );
        continue;
      }
      for (final expectation in rule.expectations) {
        results.add(_checkExpectation(rule, expectation, snapshot));
      }
    }
    return results;
  }

  ValidationResult _checkExpectation(
    Rule rule,
    Expectation expectation,
    UiSnapshot snapshot,
  ) {
    final node = snapshot.find(expectation.element);

    // An element that is not on the screen is not visible, which can
    // legitimately satisfy an expectation of `visible: false`.
    if (node == null) {
      final satisfied =
          expectation.property == 'visible' && expectation.equals == false;
      return satisfied
          ? ValidationResult.pass(
              validatorId: id,
              elementId: expectation.element,
              message: 'given "${rule.condition}", '
                  '"${expectation.element}" is absent as required',
            )
          : ValidationResult.fail(
              validatorId: id,
              elementId: expectation.element,
              message: 'given "${rule.condition}", "${expectation.element}" '
                  'should have ${expectation.property} = '
                  '${expectation.equals}, but it is not on the screen',
              expected: '${expectation.equals}',
              actual: 'absent',
            );
    }

    final read = readPropertyOf(node, expectation.property);
    if (read is PropertyAmbiguous) {
      return ValidationResult.error(
        validatorId: id,
        elementId: expectation.element,
        // A duplicate test id is a UI identity defect, not an API one.
        dimension: ValidationDimension.ui,
        message: 'given "${rule.condition}", ${expectation.element}: '
            '${read.reason}',
      );
    }
    final actual = (read as PropertyValue).value;
    if (actual?.toString() == expectation.equals?.toString()) {
      return ValidationResult.pass(
        validatorId: id,
        elementId: expectation.element,
        message: 'given "${rule.condition}", ${expectation.element}.'
            '${expectation.property} is ${expectation.equals}',
      );
    }

    return ValidationResult.fail(
      validatorId: id,
      elementId: expectation.element,
      message: 'given "${rule.condition}", ${expectation.element}.'
          '${expectation.property} should be ${expectation.equals} '
          'but is $actual',
      expected: '${expectation.equals}',
      actual: '$actual',
    );
  }
}
