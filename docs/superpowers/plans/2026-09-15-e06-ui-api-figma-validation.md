# E-06 UI / API / Figma Deterministic Validation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user-written test case validate the rendered Flutter UI against both an API response and a Figma design, and report UI / API / FIGMA / VISUAL / OVERALL as five independent, deterministic verdicts that cannot hide one another.

**Architecture:** Three additions to an existing, mature platform. (1) A `ValidationDimension` stamped on every `ValidationResult` **by the validator that produced it**, rolled up by a *computed* getter on `RunResult` so the block cannot drift from the flat verdict. (2) An `apiSource:` block in `mappings/<screen>.yaml` that the runner fetches **only when captured traffic cannot supply the required response**. (3) A `figmaSource:` block resolved through the existing `FigmaClient` and its cache. No new DSL, no new comparison engine, no AI.

**Tech Stack:** Dart 3.12 / pub workspaces. `flutter_testsmith_engine` (pure Dart, never Flutter), `flutter_testsmith_cli` (`dart:io`), `flutter_testsmith_protocol`, `integrations/figma_client`. Testing with `package:test`. YAML via `package:yaml`.

**Spec:** [docs/superpowers/specs/2026-09-15-e06-ui-api-figma-validation-design.md](../specs/2026-09-15-e06-ui-api-figma-validation-design.md)

## Global Constraints

- **DO NOT COMMIT AND DO NOT PUSH.** E-06 §21. Every task ends with verification, not a commit. Work accumulates in the working tree until the user approves. This overrides the commit step the writing-plans skill normally prescribes.
- **No AI.** E-06 §14. Nothing added here may call `ai_client`, and `packages/flutter_testsmith_engine/test/ai_boundaries_test.dart` must keep passing.
- **No E-05 authentication automation.** E-06 §19. Task 1 *relocates* an existing secret primitive; it adds no auth flow, no credential entry, no login driving.
- **`flutter_testsmith_engine` must never depend on Flutter**, and **`flutter_testsmith` must never depend on `flutter_testsmith_engine`.** Enforced by `scripts/package_boundaries.dart`.
- **No confidence field on any deterministic result, at any depth.** Asserted by existing tests.
- **Analyzer must be clean at `--fatal-infos`.**
- Existing tests are never deleted or weakened. E-06 §17.
- Secrets are referenced as `env:NAME`, never written literally. Refused at parse time.
- `RunResult.schemaVersion` goes `1.0` → `1.1`, additively — no existing key changes meaning.

**Verification command used throughout:**

```bash
cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos
```

---

## File Structure

**Created**

| Path | Responsibility |
|---|---|
| `packages/flutter_testsmith_engine/lib/src/secrets/secret_ref.dart` | `SecretRef` / `Secret` / `SecretResolver` / `MissingSecretException` / `redactionMarker`. Neutral primitive, knows nothing of auth. |
| `packages/flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart` | `env:` resolution from process env then `.env`. |
| `packages/flutter_testsmith_engine/lib/src/validation/validation_dimension.dart` | `ValidationDimension` enum. |
| `packages/flutter_testsmith_engine/lib/src/reporting/dimension_verdict.dart` | `DimensionVerdict`, aggregation, overall precedence. |
| `packages/flutter_testsmith_engine/lib/src/validation/api_source.dart` | `ApiSource` model + parsing. |
| `packages/flutter_testsmith_engine/lib/src/validation/api_fetcher.dart` | `ApiFetcher` interface, `FetchOutcome`, normalisation to `ApiResponsePayload`. |
| `packages/flutter_testsmith_engine/lib/src/validation/api_acquisition.dart` | Captured-preferred selection, fallback rule, provenance. |
| `packages/flutter_testsmith_engine/lib/src/validation/figma_source.dart` | `FigmaSource` model + parsing. |
| `packages/flutter_testsmith_cli/lib/src/http_api_fetcher.dart` | `dart:io` `ApiFetcher`. |
| `packages/flutter_testsmith_cli/lib/src/figma_source_resolver.dart` | Resolves `figmaSource:` via `FigmaClient` + cache. |
| `docs/E-06_UI_API_FIGMA_VALIDATION.md` | The milestone document. |

**Modified**

| Path | Change |
|---|---|
| `packages/flutter_testsmith_engine/lib/src/validation/validation_result.dart` | `dimension` field, `inDimension()`. |
| `packages/flutter_testsmith_engine/lib/src/validation/validators.dart` | `ScreenValidator.dimension`, `runValidator()`, 4 overrides, acquisition hook on `ValidationContext`. |
| `packages/flutter_testsmith_engine/lib/src/validation/figma_structure_validator.dart` | `dimension` getter + 2 overrides. |
| `packages/flutter_testsmith_engine/lib/src/visual/visual_validator.dart` | Stamp `visual`. |
| `packages/flutter_testsmith_engine/lib/src/validation/mappings.dart` | `apiSource:` and `figmaSource:` blocks. |
| `packages/flutter_testsmith_engine/lib/src/reporting/run_result.dart` | `dimensions` getter, schema 1.1. |
| `packages/flutter_testsmith_engine/lib/src/reporting/html_reporter.dart` | Dimension block. |
| `packages/flutter_testsmith_engine/lib/src/reporting/suite_result.dart` | Carry dimensions. |
| `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart` | Barrel exports. |
| `packages/flutter_testsmith_cli/lib/src/flow_executor.dart` | Wire acquisition + `runValidator` + terminal block. |
| `packages/flutter_testsmith_cli/lib/src/project_config.dart` | Resolve `figmaSource:`. |
| `packages/flutter_testsmith_engine/lib/src/auth/*.dart`, `device/*.dart`, `dsl/steps.dart` | Import-path change only (Task 1). |

---

## Task 1: Relocate secret handling to a neutral primitive

E-06 must not depend on uncommitted E-05 code. `SecretRef` currently lives under `auth/`. It moves; the dependency direction becomes `auth/ → secrets/`, never the reverse.

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/secrets/secret_ref.dart` (moved content)
- Delete: `packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart`
- Create: `packages/flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart` (moved content)
- Delete: `packages/flutter_testsmith_cli/lib/src/env_secret_resolver.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/auth/auth_flow.dart:7`, `auth_result.dart:5`, `device/adb_device_controller.dart:3`, `device/device_controller.dart:5`, `dsl/steps.dart:3`, `lib/flutter_testsmith_engine.dart:14`
- Modify: `packages/flutter_testsmith_cli/lib/src/auth_runner.dart`, `lib/src/commands/auth_command.dart` (import path only)
- Test: `packages/flutter_testsmith_engine/test/secret_ref_test.dart`, `packages/flutter_testsmith_cli/test/env_secret_resolver_test.dart` (import path only)

**Interfaces:**
- Consumes: nothing.
- Produces: `SecretRef{scheme, name}`, `SecretRef.parse(String, {required String source})`, `Secret.expose() -> String`, `Secret.toString() -> '[REDACTED]'`, `abstract interface SecretResolver { bool isPresent(SecretRef); Secret resolve(SecretRef); }`, `MissingSecretException`, `const String redactionMarker`, `EnvSecretResolver({DotEnv?, Map<String,String>?})`. Tasks 4–7 depend on these.

- [ ] **Step 1: Write the failing test proving the neutral location exists and auth is not required to use it**

Create `packages/flutter_testsmith_engine/test/secrets_neutrality_test.dart`:

```dart
import 'package:test/test.dart';
// Deliberately imports the neutral path only. If this file ever needs an
// `auth/` import to compile, the primitive is not neutral.
import 'package:flutter_testsmith_engine/src/secrets/secret_ref.dart';

void main() {
  test('a secret reference parses without any authentication code', () {
    final ref = SecretRef.parse('env:EXAMPLE_API_TOKEN', source: 'test');
    expect(ref.scheme, 'env');
    expect(ref.name, 'EXAMPLE_API_TOKEN');
  });

  test('a literal credential is refused', () {
    expect(
      () => SecretRef.parse('sk-live-abc123', source: 'test'),
      throwsA(isA<SecretRefFormatException>()),
    );
  });

  test('a resolved secret renders as the redaction marker', () {
    expect(const Secret('hunter2').toString(), redactionMarker);
    expect(const Secret('hunter2').expose(), 'hunter2');
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/secrets_neutrality_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'flutter_testsmith_engine' ... src/secrets/secret_ref.dart` (the file does not exist yet).

- [ ] **Step 3: Move the file**

```bash
cd /d/Repositories/flutter-ai-test-platform
mkdir -p packages/flutter_testsmith_engine/lib/src/secrets
mv packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart \
   packages/flutter_testsmith_engine/lib/src/secrets/secret_ref.dart
mkdir -p packages/flutter_testsmith_cli/lib/src/secrets
mv packages/flutter_testsmith_cli/lib/src/env_secret_resolver.dart \
   packages/flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart
```

Then update the doc comment at the top of `secrets/secret_ref.dart` so it no longer describes itself as an auth concern. Replace the class-level comment on `SecretRef` with:

```dart
/// *Where* a credential lives, never *what* it is.
///
/// This is the half that is allowed to travel: into YAML, into a step
/// description, into a report, onto the console. Keeping the halves in
/// two types is what turns "did we just print the secret?" from a review
/// question into a compiler question.
///
/// Neutral by construction: nothing in this directory knows that
/// authentication, an API token or a Figma token exist. Each of those is
/// a consumer. The dependency runs one way.
```

- [ ] **Step 4: Update the six import sites**

```bash
cd /d/Repositories/flutter-ai-test-platform
# within auth/: sibling import becomes a parent-relative one
sed -i "s|import 'secret_ref.dart';|import '../secrets/secret_ref.dart';|" \
  packages/flutter_testsmith_engine/lib/src/auth/auth_flow.dart \
  packages/flutter_testsmith_engine/lib/src/auth/auth_result.dart
# elsewhere in the engine
sed -i "s|import '../auth/secret_ref.dart';|import '../secrets/secret_ref.dart';|" \
  packages/flutter_testsmith_engine/lib/src/device/adb_device_controller.dart \
  packages/flutter_testsmith_engine/lib/src/device/device_controller.dart \
  packages/flutter_testsmith_engine/lib/src/dsl/steps.dart
# the barrel
sed -i "s|export 'src/auth/secret_ref.dart';|export 'src/secrets/secret_ref.dart';|" \
  packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart
# the CLI's own resolver import, wherever it appears
grep -rl "env_secret_resolver.dart" packages/flutter_testsmith_cli --include="*.dart" \
  | xargs sed -i "s|'env_secret_resolver.dart'|'secrets/env_secret_resolver.dart'|; s|'../env_secret_resolver.dart'|'../secrets/env_secret_resolver.dart'|"
```

Then fix the relative import inside the moved resolver — it now sits one directory deeper:

```dart
// packages/flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart
import '../dotenv.dart';
```

- [ ] **Step 5: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS, including the new `secrets_neutrality_test.dart` and the pre-existing `secret_ref_test.dart`, `auth_leakage_test.dart`, `device_secret_input_test.dart`, `env_secret_resolver_test.dart`. If any of those fail with an unresolved import, its own import line still points at the old path — fix it and re-run.

- [ ] **Step 6: Prove the direction of the dependency**

```bash
cd /d/Repositories/flutter-ai-test-platform
grep -rn "auth/" packages/flutter_testsmith_engine/lib/src/secrets/ packages/flutter_testsmith_cli/lib/src/secrets/ || echo "OK: secrets/ does not reference auth/"
```
Expected: `OK: secrets/ does not reference auth/`

- [ ] **Step 7: Do NOT commit.** Leave the changes staged-free in the working tree. See Global Constraints.

---

## Task 2: Stamp a dimension on every validation result

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/validation/validation_dimension.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/validation/validation_result.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/validation/validators.dart` (lines 326, 422, 599, 657 + `ScreenValidator`)
- Modify: `packages/flutter_testsmith_engine/lib/src/validation/figma_structure_validator.dart` (line 94 + the `figma-identity` result)
- Modify: `packages/flutter_testsmith_engine/lib/src/visual/visual_validator.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`
- Test: `packages/flutter_testsmith_engine/test/validation_dimension_test.dart`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `enum ValidationDimension { ui, api, figma, visual }` each with `.wire`; `ValidationResult.dimension` (nullable `ValidationDimension`); `ValidationResult.inDimension(ValidationDimension) -> ValidationResult`; `ScreenValidator.dimension` getter; top-level `List<ValidationResult> runValidator(ScreenValidator, ValidationContext)`. Task 3 consumes `result.dimension`; Task 8 consumes `runValidator`.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/validation_dimension_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

void main() {
  test('a result with no dimension takes the validator default', () {
    const result = ValidationResult.pass(
      validatorId: 'api-to-ui',
      message: 'matches',
    );
    expect(result.dimension, isNull);
    expect(result.inDimension(ValidationDimension.api).dimension,
        ValidationDimension.api);
  });

  test('an explicitly stamped dimension survives the default', () {
    const result = ValidationResult.error(
      validatorId: 'api-to-ui',
      message: 'one test id is on two elements',
      dimension: ValidationDimension.ui,
    );
    // The validator's default is api; this result is about UI evidence.
    expect(result.inDimension(ValidationDimension.api).dimension,
        ValidationDimension.ui);
  });

  test('inDimension preserves every other field', () {
    const result = ValidationResult.fail(
      validatorId: 'figma-geometry',
      message: 'width differs',
      elementId: 'login.continue_button',
      expected: 322.0,
      actual: 282.0,
      evidence: [Evidence(kind: 'figmaNode', reference: '909:133')],
    );
    final stamped = result.inDimension(ValidationDimension.figma);
    expect(stamped.validatorId, 'figma-geometry');
    expect(stamped.status, ValidationStatus.fail);
    expect(stamped.elementId, 'login.continue_button');
    expect(stamped.expected, 322.0);
    expect(stamped.actual, 282.0);
    expect(stamped.evidence.single.reference, '909:133');
    expect(stamped.severity, Severity.critical);
  });

  test('the dimension reaches the JSON', () {
    const result = ValidationResult.pass(
      validatorId: 'ui-presence',
      message: 'present',
      dimension: ValidationDimension.ui,
    );
    expect(result.toJson()['dimension'], 'ui');
  });

  test('a result with no dimension omits the key rather than writing null',
      () {
    const result =
        ValidationResult.pass(validatorId: 'x', message: 'y');
    expect(result.toJson().containsKey('dimension'), isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/validation_dimension_test.dart`
Expected: FAIL — `ValidationDimension` is not defined.

- [ ] **Step 3: Create the enum**

`packages/flutter_testsmith_engine/lib/src/validation/validation_dimension.dart`:

```dart
/// Which source of truth a result was measured against.
///
/// "The screen is correct" is not a sentence this platform can say. It
/// can say the UI matches the API, and the UI matches the design, and
/// the steps executed - and it must say those separately, because a
/// reader told only "PASS" cannot tell which of them was checked.
///
/// Declared by the validator that produced the result, never inferred
/// from the validator's name at report time: the producing code is the
/// only code that knows what it actually compared.
enum ValidationDimension {
  /// The user-written steps, and the readability of the UI itself.
  ui('ui'),

  /// Measured against an API response.
  api('api'),

  /// Measured against a Figma design.
  figma('figma'),

  /// Measured against an accepted screenshot baseline.
  ///
  /// Already a distinct dimension of this platform before E-06: its own
  /// step flag, its own validator, its own config block, its own
  /// on-disk store and its own enablement rule.
  visual('visual');

  const ValidationDimension(this.wire);

  final String wire;
}
```

- [ ] **Step 4: Add the field to `ValidationResult`**

In `validation_result.dart`, add `dimension` to the private constructor and to all four factories, add the field, add `inDimension`, and emit it in `toJson`.

```dart
  const ValidationResult._({
    required this.validatorId,
    required this.status,
    required this.message,
    this.severity = Severity.critical,
    this.elementId,
    this.expected,
    this.actual,
    this.evidence = const [],
    this.facts = const {},
    this.dimension,
  });
```

Each factory gains `ValidationDimension? dimension,` in its parameter list and `dimension: dimension,` in its forwarding call. For example `pass`:

```dart
  const ValidationResult.pass({
    required String validatorId,
    required String message,
    String? elementId,
    Object? expected,
    Object? actual,
    List<Evidence> evidence = const [],
    Map<String, Object?> facts = const {},
    ValidationDimension? dimension,
  }) : this._(
          validatorId: validatorId,
          status: ValidationStatus.pass,
          message: message,
          elementId: elementId,
          expected: expected,
          actual: actual,
          evidence: evidence,
          facts: facts,
          severity: Severity.info,
          dimension: dimension,
        );
```

Do the same for `fail`, `skip` and `error`. Then the field and the stamp:

```dart
  /// Which source of truth this was measured against.
  ///
  /// Null only between construction and the producing validator stamping
  /// its default. Nothing that reaches a report carries a null, and a
  /// test asserts it.
  final ValidationDimension? dimension;

  /// This result with [fallback] applied, if it does not already name a
  /// dimension.
  ///
  /// An explicit dimension always wins: a validator whose default is
  /// `api` still emits `ui` results when the reason it could not compare
  /// was that the UI could not be read.
  ValidationResult inDimension(ValidationDimension fallback) =>
      dimension != null
          ? this
          : ValidationResult._(
              validatorId: validatorId,
              status: status,
              message: message,
              severity: severity,
              elementId: elementId,
              expected: expected,
              actual: actual,
              evidence: evidence,
              facts: facts,
              dimension: fallback,
            );
```

And in `toJson`, immediately after `'severity'`:

```dart
        if (dimension != null) 'dimension': dimension!.wire,
```

Add the import at the top of the file:

```dart
import 'validation_dimension.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/validation_dimension_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 6: Add the validator default and the runner helper**

In `validators.dart`, extend the interface and add the helper:

```dart
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
/// cannot forget - and so no report-time table has to guess from a
/// validator's name.
List<ValidationResult> runValidator(
  ScreenValidator validator,
  ValidationContext context,
) =>
    [for (final r in validator.validate(context)) r.inDimension(validator.dimension)];
```

Add `import 'validation_dimension.dart';` to `validators.dart`.

Then add the getter to each implementation:

```dart
// ApiToUiValidator
@override
ValidationDimension get dimension => ValidationDimension.api;

// UiPresenceValidator
@override
ValidationDimension get dimension => ValidationDimension.ui;

// RulesValidator — a rule's condition is evaluated against the API
// response (Condition.evaluate takes response.readPath and has no access
// to the UI snapshot), so a rule is an API-to-UI consistency statement
// in conditional form.
@override
ValidationDimension get dimension => ValidationDimension.api;
```

And in `figma_structure_validator.dart`:

```dart
@override
ValidationDimension get dimension => ValidationDimension.figma;
```

- [ ] **Step 7: Apply the six overrides**

Write this test first, in `packages/flutter_testsmith_engine/test/validation_dimension_test.dart` (append to the existing `main`):

```dart
  test('a UI-evidence failure is never attributed to API or Figma', () {
    // No UI tree captured at all: the tool could not read the UI, so
    // nothing was compared against the API. Reporting this as an API
    // result would make the API dimension speak for a check that never
    // ran.
    final context = ValidationContext(
      session: ScreenSession(
        screenId: '/product/details',
        enteredAt: DateTime.utc(2026, 9, 15),
      ),
      mappings: MappingsFile.parse('''
screen: /product/details
mappings:
  - target: product.price
    source: response.price
''', source: 'test'),
    );

    final results = runValidator(const ApiToUiValidator(), context);
    expect(results.single.status, ValidationStatus.error);
    expect(results.single.dimension, ValidationDimension.ui);
  });
```

Add the needed imports to the test file: `package:flutter_testsmith_engine/flutter_testsmith_engine.dart` already exports `ScreenSession` and `MappingsFile`.

Now apply the overrides. At each site add `dimension: ValidationDimension.ui,`:

- `validators.dart:326` — `ApiToUiValidator`, `'no UI tree was captured for this screen, so nothing could be compared'`
- `validators.dart:422` — `ApiToUiValidator`, the `read is PropertyAmbiguous` error
- `validators.dart:657` — `RulesValidator`, the `read is PropertyAmbiguous` error
- `figma_structure_validator.dart:94` — `'no UI tree was captured for this screen, so the design ...'`
- the single `'figma-identity'` result in `figma_structure_validator.dart` — a duplicate test id is a UI identity defect; the design is not in question

`validators.dart:599` is a ternary covering two different causes and needs splitting:

```dart
    final snapshot = context.snapshot;
    final response = context.response;
    if (snapshot == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          message: 'rules need a UI tree, and none was captured',
          dimension: ValidationDimension.ui,
        ),
      ];
    }
    if (response == null) {
      return [
        ValidationResult.error(
          validatorId: id,
          message: 'rules need an API response: '
              '${ApiToUiValidator._noResponseMessage(context)}',
          // No dimension: the validator default (api) is correct here.
        ),
      ];
    }
```

- [ ] **Step 8: Stamp the visual validator**

`VisualValidator` is not a `ScreenValidator`. In `visual_validator.dart`, wrap its returned list at the end of `validate(...)`:

```dart
    return [
      for (final r in results) r.inDimension(ValidationDimension.visual),
    ];
```

Add `import '../validation/validation_dimension.dart';`.

- [ ] **Step 9: Export and switch the call sites**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart` add, next to the other validation exports:

```dart
export 'src/validation/validation_dimension.dart';
```

In `packages/flutter_testsmith_cli/lib/src/flow_executor.dart`, replace the validator fan-out in `_validate` with the stamping helper:

```dart
    final results = <ValidationResult>[
      if (step.runsUi) ...runValidator(const UiPresenceValidator(), context),
      if (step.runsApi) ...runValidator(const ApiToUiValidator(), context),
      if (step.runsRules) ...runValidator(const RulesValidator(), context),
      if (step.runsFigma)
        ...runValidator(const FigmaStructureValidator(), context),
    ];
```

The `ValidationResult.skip` added a few lines below for a missing baseline must also be stamped:

```dart
      results.add(
        ValidationResult.skip(
          validatorId: VisualValidator.id,
          dimension: ValidationDimension.visual,
          message: 'no screenshot baseline for "$screenId" yet. Automatic '
              'mode will not record one, because that writes a file into '
              'the repository. Run this step with `visual: true` once to '
              'record it.',
        ),
      );
```

- [ ] **Step 10: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS. Existing validator tests are unaffected — `dimension` is additive and nullable.

- [ ] **Step 11: Do NOT commit.**

---

## Task 3: Roll dimensions up into a verdict

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/reporting/dimension_verdict.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/reporting/run_result.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`
- Test: `packages/flutter_testsmith_engine/test/dimension_verdict_test.dart`

**Interfaces:**
- Consumes: `ValidationDimension`, `ValidationResult.dimension` (Task 2).
- Produces: `DimensionVerdict{dimension, status, reason, counts}`; `RunResult.dimensions -> Map<ValidationDimension, DimensionVerdict>`; `RunResult.overall -> ValidationStatus`. Task 8 renders both.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/dimension_verdict_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

ValidationResult _r(ValidationStatus s, ValidationDimension d) =>
    switch (s) {
      ValidationStatus.pass =>
        ValidationResult.pass(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.fail =>
        ValidationResult.fail(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.skip =>
        ValidationResult.skip(validatorId: 'v', message: 'm', dimension: d),
      ValidationStatus.error =>
        ValidationResult.error(validatorId: 'v', message: 'm', dimension: d),
    };

RunResult _run(List<ValidationResult> results, {List<StepOutcome>? steps}) =>
    RunResult(
      flowName: 'f',
      appId: 'a',
      device: 'd',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: Duration.zero,
      steps: steps ??
          const [
            StepOutcome(
              description: 'launch the app',
              status: StepStatus.ok,
              durationMs: 1,
            ),
          ],
      screens: [
        ScreenResult(screenId: '/s', report: ValidationReport(results)),
      ],
    );

void main() {
  group('precedence within a dimension', () {
    test('error outranks fail', () {
      final run = _run([
        _r(ValidationStatus.fail, ValidationDimension.api),
        _r(ValidationStatus.error, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.error);
    });

    test('fail outranks pass', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.fail);
    });

    test('pass outranks skip', () {
      final run = _run([
        _r(ValidationStatus.skip, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.api),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
    });

    test('a dimension with nothing in it is SKIP, never PASS', () {
      final run = _run([_r(ValidationStatus.pass, ValidationDimension.ui)]);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.skip);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.skip);
    });

    test('every dimension is always present in the block', () {
      final run = _run([_r(ValidationStatus.pass, ValidationDimension.ui)]);
      expect(run.dimensions.keys, containsAll(ValidationDimension.values));
    });
  });

  group('the milestone combinations', () {
    test('API PASS + Figma PASS + UI PASS -> overall PASS', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.overall, ValidationStatus.pass);
      expect(run.passed, isTrue);
    });

    test('API FAIL + Figma PASS + UI PASS -> overall FAIL', () {
      final run = _run([
        _r(ValidationStatus.fail, ValidationDimension.api),
        _r(ValidationStatus.pass, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.dimensions[ValidationDimension.figma]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });

    test('API PASS + Figma FAIL + UI PASS -> overall FAIL', () {
      final run = _run([
        _r(ValidationStatus.pass, ValidationDimension.api),
        _r(ValidationStatus.fail, ValidationDimension.figma),
        _r(ValidationStatus.pass, ValidationDimension.ui),
      ]);
      expect(run.dimensions[ValidationDimension.api]!.status,
          ValidationStatus.pass);
      expect(run.overall, ValidationStatus.fail);
    });

    test('a passing dimension cannot hide a failing one', () {
      for (final failing in ValidationDimension.values) {
        final run = _run([
          for (final d in ValidationDimension.values)
            _r(d == failing ? ValidationStatus.fail : ValidationStatus.pass, d),
        ]);
        expect(run.overall, ValidationStatus.fail,
            reason: 'a FAIL in $failing was hidden');
      }
    });
  });

  group('the equivalence that pins E-03 and E-04', () {
    test('passed is true exactly when overall does not block a pass', () {
      for (final a in ValidationStatus.values) {
        for (final b in ValidationStatus.values) {
          final run = _run([
            _r(a, ValidationDimension.api),
            _r(b, ValidationDimension.figma),
          ]);
          final blocks = run.overall == ValidationStatus.fail ||
              run.overall == ValidationStatus.error;
          expect(run.passed, !blocks,
              reason: 'api=$a figma=$b gave overall=${run.overall}');
        }
      }
    });

    test('a failed step lands in UI and blocks the overall verdict', () {
      final run = _run(
        [_r(ValidationStatus.pass, ValidationDimension.api)],
        steps: const [
          StepOutcome(
            description: 'tap "home.open_product"',
            status: StepStatus.failed,
            durationMs: 5,
          ),
        ],
      );
      expect(run.dimensions[ValidationDimension.ui]!.status,
          ValidationStatus.fail);
      expect(run.overall, ValidationStatus.fail);
      expect(run.passed, isFalse);
    });
  });

  test('the block reaches the JSON, and the schema version moves', () {
    final json = _run([
      _r(ValidationStatus.pass, ValidationDimension.api),
    ]).toJson();
    expect(json['resultSchemaVersion'], '1.1');
    final dims = json['dimensions']! as Map<String, Object?>;
    expect((dims['api']! as Map)['status'], 'pass');
    expect((dims['figma']! as Map)['status'], 'skip');
    expect(json['overall'], 'pass');
    // Nothing existing changed meaning.
    expect(json['passed'], isTrue);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/dimension_verdict_test.dart`
Expected: FAIL — `DimensionVerdict` / `RunResult.dimensions` are not defined.

- [ ] **Step 3: Create the verdict model**

`packages/flutter_testsmith_engine/lib/src/reporting/dimension_verdict.dart`:

```dart
import 'package:meta/meta.dart';

import '../validation/validation_dimension.dart';
import '../validation/validation_result.dart';

/// One dimension's verdict, and what it rests on.
@immutable
class DimensionVerdict {
  const DimensionVerdict({
    required this.dimension,
    required this.status,
    required this.counts,
    this.reason,
  });

  final ValidationDimension dimension;
  final ValidationStatus status;

  /// How many results of each status contributed.
  final Map<String, int> counts;

  /// Why this is not a PASS. Null when it is.
  ///
  /// Taken from the first result that decided the verdict, so a reader
  /// gets the actionable sentence without opening the detail.
  final String? reason;

  Map<String, Object?> toJson() => {
        'status': status.wire,
        'counts': counts,
        if (reason != null) 'reason': reason,
      };

  @override
  String toString() => '${dimension.wire}: ${status.wire}';
}

/// E-03's precedence, applied to a set of statuses.
///
/// ERROR > FAIL > PASS > SKIP. SKIP last is the line that does the work:
/// a dimension that was never checked reports SKIP and never PASS,
/// because a PASS is a positive claim and a claim needs something to
/// have been compared.
ValidationStatus aggregateStatus(Iterable<ValidationStatus> statuses) {
  var sawPass = false;
  var sawFail = false;
  for (final status in statuses) {
    switch (status) {
      case ValidationStatus.error:
        return ValidationStatus.error;
      case ValidationStatus.fail:
        sawFail = true;
      case ValidationStatus.pass:
        sawPass = true;
      case ValidationStatus.skip:
        break;
    }
  }
  if (sawFail) return ValidationStatus.fail;
  if (sawPass) return ValidationStatus.pass;
  return ValidationStatus.skip;
}

/// Builds one dimension's verdict from the results attributed to it.
DimensionVerdict verdictFor(
  ValidationDimension dimension,
  List<ValidationResult> results,
) {
  final status = aggregateStatus(results.map((r) => r.status));
  final decisive = switch (status) {
    ValidationStatus.error =>
      results.where((r) => r.status == ValidationStatus.error).firstOrNull,
    ValidationStatus.fail =>
      results.where((r) => r.status == ValidationStatus.fail).firstOrNull,
    ValidationStatus.skip =>
      results.where((r) => r.status == ValidationStatus.skip).firstOrNull,
    ValidationStatus.pass => null,
  };

  return DimensionVerdict(
    dimension: dimension,
    status: status,
    reason: status == ValidationStatus.skip && results.isEmpty
        ? 'nothing was checked in this dimension'
        : decisive?.message,
    counts: {
      for (final s in ValidationStatus.values)
        s.wire: results.where((r) => r.status == s).length,
    },
  );
}
```

- [ ] **Step 4: Add the rollup to `RunResult`**

In `run_result.dart`, bump the schema and add the getters. Add imports:

```dart
import '../validation/validation_dimension.dart';
import 'dimension_verdict.dart';
```

Change the version:

```dart
  /// Versioned separately from the protocol: a consumer of reports
  /// should not have to track the wire format as well.
  ///
  /// 1.1 adds `dimensions` and `overall`. Purely additive - every key
  /// that existed at 1.0 keeps its meaning, so a 1.0 consumer is
  /// unaffected.
  static const String schemaVersion = '1.1';
```

Add, after `passed`:

```dart
  /// Every validation result in the run, with the step outcomes and the
  /// API checks folded in as results of their own.
  ///
  /// Steps are UI: they are the execution of the user-written test.
  /// `expectApi` outcomes are API: they are assertions about the API.
  List<ValidationResult> get _allResults => [
        for (final step in steps)
          switch (step.status) {
            StepStatus.ok => ValidationResult.pass(
                validatorId: 'step',
                message: step.description,
                dimension: ValidationDimension.ui,
              ),
            StepStatus.failed => ValidationResult.fail(
                validatorId: 'step',
                message: step.detail ?? step.description,
                dimension: ValidationDimension.ui,
              ),
            StepStatus.skipped => ValidationResult.skip(
                validatorId: 'step',
                message: step.description,
                dimension: ValidationDimension.ui,
              ),
          },
        for (final check in apiChecks)
          if (check.satisfied)
            ValidationResult.pass(
              validatorId: 'expect-api',
              message: check.describe(),
              dimension: ValidationDimension.api,
            )
          else
            ValidationResult.fail(
              validatorId: 'expect-api',
              message: check.describe(),
              dimension: ValidationDimension.api,
            ),
        for (final screen in screens) ...screen.report.results,
      ];

  /// One verdict per dimension. Every dimension is always present.
  ///
  /// Computed, never stored. That is the property this rests on: the
  /// block cannot disagree with [passed], because it is derived from the
  /// same fields.
  Map<ValidationDimension, DimensionVerdict> get dimensions {
    final all = _allResults;
    return {
      for (final dimension in ValidationDimension.values)
        dimension: verdictFor(
          dimension,
          [for (final r in all) if (r.dimension == dimension) r],
        ),
    };
  }

  /// The deterministic verdict over every dimension.
  ///
  /// [passed] is true exactly when this does not block a pass - asserted
  /// as a property test over every combination, so E-03's and E-04's
  /// verdicts and exit codes are provably unmoved by the dimension
  /// block.
  ValidationStatus get overall =>
      aggregateStatus(dimensions.values.map((v) => v.status));
```

Add to `toJson`, after `'passed'`:

```dart
        'overall': overall.wire,
        'dimensions': {
          for (final entry in dimensions.entries)
            entry.key.wire: entry.value.toJson(),
        },
```

- [ ] **Step 5: Export it**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`, beside the other reporting exports:

```dart
export 'src/reporting/dimension_verdict.dart';
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/dimension_verdict_test.dart`
Expected: PASS.

If `firstOrNull` is unresolved, add `import 'dart:collection';` — it comes from `package:collection`'s `IterableExtension` in older SDKs; on Dart 3.12 it is in `dart:core` for `Iterable`. If the analyzer objects, replace `.firstOrNull` with:

```dart
    final matches = results.where((r) => r.status == status).toList();
    final decisive = matches.isEmpty ? null : matches.first;
```

- [ ] **Step 7: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS. `packages/flutter_testsmith_engine/test/reporting_test.dart` and `suite_report_test.dart` may assert on `resultSchemaVersion`; update those assertions from `'1.0'` to `'1.1'` — that is the one intended change, and it is additive.

- [ ] **Step 8: Do NOT commit.**

---

## Task 4: Parse `apiSource:` and `figmaSource:`

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/validation/api_source.dart`
- Create: `packages/flutter_testsmith_engine/lib/src/validation/figma_source.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/validation/mappings.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`
- Test: `packages/flutter_testsmith_engine/test/api_source_test.dart`, `packages/flutter_testsmith_engine/test/figma_source_test.dart`

**Interfaces:**
- Consumes: `SecretRef` (Task 1).
- Produces: `ApiSource{baseUrl, method, endpoint, token, headers, query, body}` with `ApiSource.requiredEndpoint -> ApiEndpoint` and `ApiSource.resolvedUri(String baseUrl) -> Uri`; `FigmaSource{url, token, mappingPath}`; `MappingsFile.apiSource`, `MappingsFile.figmaSource`. Tasks 5–7 consume these.

- [ ] **Step 1: Write the failing tests**

Create `packages/flutter_testsmith_engine/test/api_source_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

MappingsFile _parse(String yaml) =>
    MappingsFile.parse(yaml, source: 'test.yaml');

void main() {
  test('an apiSource block parses', () {
    final file = _parse('''
screen: /product/details
apiSource:
  baseUrl: env:EXAMPLE_API_BASE
  method: GET
  endpoint: /products/123
  token: env:EXAMPLE_API_TOKEN
''');
    final source = file.apiSource!;
    expect(source.baseUrl, 'env:EXAMPLE_API_BASE');
    expect(source.method, 'GET');
    expect(source.endpoint, '/products/123');
    expect(source.token!.name, 'EXAMPLE_API_TOKEN');
  });

  test('a literal token is refused at parse time', () {
    expect(
      () => _parse('''
screen: /s
apiSource:
  baseUrl: https://api.example.com
  method: GET
  endpoint: /p
  token: sk-live-abc123
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('an unknown key is refused and the nearest is suggested', () {
    expect(
      () => _parse('''
screen: /s
apiSource:
  baseUrl: https://api.example.com
  methd: GET
  endpoint: /p
'''),
      throwsA(
        isA<MappingsFormatException>().having(
          (e) => e.message,
          'message',
          contains('method'),
        ),
      ),
    );
  });

  test('a missing method or endpoint is refused', () {
    expect(
      () => _parse('screen: /s\napiSource:\n  baseUrl: https://a.example\n'),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('the required endpoint is derived from the base URL path', () {
    // The application calls /api/v1/products/123. Matching on
    // /products/123 alone would miss it.
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example/api/v1
  method: GET
  endpoint: /products/123
''').apiSource!;
    final endpoint = source.requiredEndpoint('https://host.example/api/v1');
    expect(endpoint.method, 'GET');
    expect(endpoint.path, '/api/v1/products/123');
    expect(endpoint.matches('GET', '/api/v1/products/123'), isTrue);
    expect(endpoint.matches('GET', '/products/123'), isFalse);
  });

  test('a base URL with no path yields the endpoint unchanged', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
''').apiSource!;
    expect(source.requiredEndpoint('https://host.example').path,
        '/products/123');
  });

  test('a trailing slash on the base URL does not double up', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example/api/
  method: GET
  endpoint: /products/123
''').apiSource!;
    expect(source.requiredEndpoint('https://host.example/api/').path,
        '/api/products/123');
  });

  test('headers, query and body are optional and parse', () {
    final source = _parse('''
screen: /s
apiSource:
  baseUrl: https://host.example
  method: POST
  endpoint: /search
  headers:
    Accept: application/json
  query:
    include: pricing
  body: '{"q":"shoes"}'
''').apiSource!;
    expect(source.headers['Accept'], 'application/json');
    expect(source.query['include'], 'pricing');
    expect(source.body, '{"q":"shoes"}');
    expect(source.resolvedUri('https://host.example').toString(),
        'https://host.example/search?include=pricing');
  });

  test('a screen with no apiSource has none', () {
    expect(_parse('screen: /s').apiSource, isNull);
  });
}
```

Create `packages/flutter_testsmith_engine/test/figma_source_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

MappingsFile _parse(String yaml) =>
    MappingsFile.parse(yaml, source: 'test.yaml');

void main() {
  test('a figmaSource block parses', () {
    final source = _parse('''
screen: /product/details
figmaSource:
  url: https://figma.com/design/abc123/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/product_details.mapping.yaml
''').figmaSource!;
    expect(source.url, contains('node-id=909-1'));
    expect(source.token.name, 'FIGMA_TOKEN');
    expect(source.mappingPath, 'figma/product_details.mapping.yaml');
  });

  test('a literal Figma token is refused at parse time', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: figd_realtokenvalue
  mapping: m.yaml
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a url that names no node is refused', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/File
  token: env:FIGMA_TOKEN
  mapping: m.yaml
'''),
      throwsA(
        isA<MappingsFormatException>()
            .having((e) => e.message, 'message', contains('node-id')),
      ),
    );
  });

  test('an unknown key is refused', () {
    expect(
      () => _parse('''
screen: /s
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: env:FIGMA_TOKEN
  mappng: m.yaml
'''),
      throwsA(isA<MappingsFormatException>()),
    );
  });

  test('a screen with no figmaSource has none', () {
    expect(_parse('screen: /s').figmaSource, isNull);
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_source_test.dart packages/flutter_testsmith_engine/test/figma_source_test.dart`
Expected: FAIL — `apiSource` / `figmaSource` are not members of `MappingsFile`.

- [ ] **Step 3: Create `ApiSource`**

`packages/flutter_testsmith_engine/lib/src/validation/api_source.dart`:

```dart
import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';
import 'response_source.dart';

/// How the runner may fetch this screen's API response for itself.
///
/// A **fallback**, never the first choice. Captured traffic - what the
/// application actually received - is always preferred, because
/// asserting against the server's own reply proves only that the server
/// works, and because a response served from the app's own cache appears
/// in one and not the other. This exists for the case where the capture
/// could not supply what the screen declared it needed.
@immutable
class ApiSource {
  const ApiSource({
    required this.baseUrl,
    required this.method,
    required this.endpoint,
    this.token,
    this.headers = const {},
    this.query = const {},
    this.body,
  });

  /// The development or staging base, or an `env:` reference to one.
  ///
  /// Resolved through the same mechanism as a secret so a missing value
  /// fails with the same actionable message - but it is a URL, not a
  /// credential, and is allowed to appear in a report.
  final String baseUrl;

  final String method;

  /// The path under [baseUrl].
  final String endpoint;

  /// A reference to the credential, never the credential.
  final SecretRef? token;

  final Map<String, String> headers;
  final Map<String, String> query;
  final String? body;

  /// The full URI to request.
  Uri resolvedUri(String resolvedBase) {
    final base = Uri.parse(resolvedBase);
    final path = _join(base.path, endpoint);
    return base.replace(
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// The captured exchange this source describes, for matching against
  /// what the application itself called.
  ///
  /// Derived from the **base URL's path plus the endpoint**, not from
  /// the endpoint alone: a base of `https://host/api/v1` with an
  /// endpoint of `/products/123` is the request the application makes as
  /// `/api/v1/products/123`, and matching on the endpoint alone would
  /// miss it entirely.
  ApiEndpoint requiredEndpoint(String resolvedBase) => ApiEndpoint(
        method.toUpperCase(),
        _join(Uri.parse(resolvedBase).path, endpoint),
      );

  static String _join(String basePath, String endpoint) {
    final left = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final right = endpoint.startsWith('/') ? endpoint : '/$endpoint';
    return '$left$right';
  }

  @override
  String toString() => 'ApiSource($method $baseUrl$endpoint)';
}
```

- [ ] **Step 4: Create `FigmaSource`**

`packages/flutter_testsmith_engine/lib/src/validation/figma_source.dart`:

```dart
import 'package:meta/meta.dart';

import '../secrets/secret_ref.dart';

/// Which design this screen is validated against, declared on the test.
///
/// Resolved at run time through the existing Figma client and its
/// on-disk cache, so two runs of the same test see the same design.
@immutable
class FigmaSource {
  const FigmaSource({
    required this.url,
    required this.token,
    required this.mappingPath,
  });

  /// The Figma Dev URL, including `node-id=`.
  final String url;

  /// A reference to the access token, never the token.
  final SecretRef token;

  /// The node-id to semantic-id mapping.
  ///
  /// Mandatory, and deliberately so: real frames name their layers
  /// `Frame 42980` and `Rectangle 91`. Inferring semantic ids from layer
  /// names produces something that looks like it works and is wrong.
  final String mappingPath;

  @override
  String toString() => 'FigmaSource($url)';
}
```

- [ ] **Step 5: Wire both into `MappingsFile`**

In `mappings.dart`, add the imports:

```dart
import '../secrets/secret_ref.dart';
import 'api_source.dart';
import 'figma_source.dart';
```

Add to `_topLevelKeys`: `'apiSource'`, `'figmaSource'`.

Add the fields and constructor parameters:

```dart
  /// How to fetch this screen's response when the capture cannot supply
  /// it. Null means captured traffic is the only source, as before.
  final ApiSource? apiSource;

  /// The design this screen is validated against, declared here rather
  /// than pulled to disk beforehand. Null falls back to
  /// `<project>/figma/<screen>.json`.
  final FigmaSource? figmaSource;
```

with `this.apiSource,` and `this.figmaSource,` in the constructor, and in `MappingsFile.parse`'s returned `MappingsFile(...)`:

```dart
      apiSource: _readApiSource(source, root['apiSource']),
      figmaSource: _readFigmaSource(source, root['figmaSource']),
```

Add the two readers as static members of `MappingsFile`:

```dart
  static const Set<String> _apiSourceKeys = {
    'baseUrl',
    'method',
    'endpoint',
    'token',
    'headers',
    'query',
    'body',
  };

  static const Set<String> _figmaSourceKeys = {'url', 'token', 'mapping'};

  /// Reads `apiSource:`.
  ///
  /// Every refusal happens before anything is launched or requested. A
  /// block that parses and fetches nothing would be the same defect as
  /// the `api:` key that was read and then ignored from Phase 4 onward.
  static ApiSource? _readApiSource(String source, Object? node) {
    if (node == null) return null;
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"apiSource" must be a mapping with baseUrl, method and endpoint',
      );
    }
    final map = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    _rejectUnknownKeys(source, map.keys, _apiSourceKeys, 'apiSource key');

    String require(String key) {
      final value = map[key];
      if (value is! String || value.trim().isEmpty) {
        throw MappingsFormatException(
          source,
          '"apiSource" needs a "$key", as in '
          '${_apiSourceExample(key)}',
        );
      }
      return value.trim();
    }

    SecretRef? token;
    final rawToken = map['token'];
    if (rawToken != null) {
      // Throws when given a literal, which is the point: a credential
      // written into a mappings file is a credential in git.
      token = SecretRef.parse('$rawToken', source: source);
    }

    return ApiSource(
      baseUrl: require('baseUrl'),
      method: require('method').toUpperCase(),
      endpoint: require('endpoint'),
      token: token,
      headers: _stringMap(source, map['headers'], 'headers'),
      query: _stringMap(source, map['query'], 'query'),
      body: map['body'] as String?,
    );
  }

  static String _apiSourceExample(String key) => switch (key) {
        'baseUrl' => '`baseUrl: env:EXAMPLE_API_BASE`',
        'method' => '`method: GET`',
        'endpoint' => '`endpoint: /products/123`',
        _ => '`$key: ...`',
      };

  static Map<String, String> _stringMap(
    String source,
    Object? node,
    String name,
  ) {
    if (node == null) return const {};
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"$name" must be a mapping of names to values',
      );
    }
    return {
      for (final entry in node.entries)
        entry.key.toString(): '${entry.value}',
    };
  }

  /// Reads `figmaSource:`.
  static FigmaSource? _readFigmaSource(String source, Object? node) {
    if (node == null) return null;
    if (node is! Map) {
      throw MappingsFormatException(
        source,
        '"figmaSource" must be a mapping with url, token and mapping',
      );
    }
    final map = node.cast<Object?, Object?>().map(
          (key, value) => MapEntry(key.toString(), value),
        );
    _rejectUnknownKeys(source, map.keys, _figmaSourceKeys, 'figmaSource key');

    String require(String key) {
      final value = map[key];
      if (value is! String || value.trim().isEmpty) {
        throw MappingsFormatException(
          source,
          '"figmaSource" needs a "$key"',
        );
      }
      return value.trim();
    }

    final url = require('url');
    if (!url.contains('node-id')) {
      throw MappingsFormatException(
        source,
        'the figmaSource url has no node-id. Open the frame in Figma and '
        'copy the link to it, which includes node-id=...',
      );
    }

    return FigmaSource(
      url: url,
      token: SecretRef.parse('${map['token']}', source: source),
      mappingPath: require('mapping'),
    );
  }
```

- [ ] **Step 6: Export both**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`:

```dart
export 'src/validation/api_source.dart';
export 'src/validation/figma_source.dart';
```

- [ ] **Step 7: Run the tests**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_source_test.dart packages/flutter_testsmith_engine/test/figma_source_test.dart`
Expected: PASS, 14 tests.

- [ ] **Step 8: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS. `packages/flutter_testsmith_engine/test/mappings_test.dart` should be unaffected — both keys are optional.

- [ ] **Step 9: Do NOT commit.**

---

## Task 5: The API fetcher

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/validation/api_fetcher.dart`
- Create: `packages/flutter_testsmith_cli/lib/src/http_api_fetcher.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`
- Test: `packages/flutter_testsmith_engine/test/api_fetcher_test.dart`

**Interfaces:**
- Consumes: `ApiSource`, `SecretRef`, `SecretResolver`.
- Produces: `abstract interface class ApiFetcher { Future<FetchOutcome> fetch({required ApiSource source, required String resolvedBaseUrl, required Secret? token}); }`; sealed `FetchOutcome` with `FetchSucceeded(ApiResponsePayload payload)` and `FetchFailed(String reason)`; `HttpApiFetcher` in `flutter_testsmith_cli`. Task 6 consumes both.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/api_fetcher_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// A fetcher that answers from a script. No network, no timing.
class ScriptedFetcher implements ApiFetcher {
  ScriptedFetcher(this.outcome);

  final FetchOutcome outcome;
  ApiSource? sawSource;
  String? sawBase;
  Secret? sawToken;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    sawSource = source;
    sawBase = resolvedBaseUrl;
    sawToken = token;
    return outcome;
  }
}

void main() {
  test('a JSON 200 becomes a readable response payload', () async {
    final fetcher = ScriptedFetcher(
      FetchSucceeded(
        jsonResponse(statusCode: 200, body: '{"price": 120}', durationMs: 7),
      ),
    );
    final outcome = await fetcher.fetch(
      source: const ApiSource(
        baseUrl: 'https://h.example',
        method: 'GET',
        endpoint: '/p',
      ),
      resolvedBaseUrl: 'https://h.example',
      token: null,
    );
    expect(outcome, isA<FetchSucceeded>());
    final payload = (outcome as FetchSucceeded).payload;
    expect(payload.statusCode, 200);
    expect(payload.readPath('price'), 120);
  });

  test('a fetched payload never carries request headers', () {
    final payload =
        jsonResponse(statusCode: 200, body: '{}', durationMs: 1);
    expect(payload.headers, isEmpty);
    expect(payload.toJson().containsKey('headers'), isFalse);
  });

  test('a failure carries a reason and no payload', () async {
    final fetcher = ScriptedFetcher(
      const FetchFailed('the connection to https://h.example was refused'),
    );
    final outcome = await fetcher.fetch(
      source: const ApiSource(
        baseUrl: 'https://h.example',
        method: 'GET',
        endpoint: '/p',
      ),
      resolvedBaseUrl: 'https://h.example',
      token: null,
    );
    expect(outcome, isA<FetchFailed>());
    expect((outcome as FetchFailed).reason, contains('refused'));
  });

  test('the token reaches the fetcher as a Secret, not a String', () async {
    final fetcher = ScriptedFetcher(
      FetchSucceeded(jsonResponse(statusCode: 200, body: '{}', durationMs: 1)),
    );
    await fetcher.fetch(
      source: const ApiSource(
        baseUrl: 'https://h.example',
        method: 'GET',
        endpoint: '/p',
      ),
      resolvedBaseUrl: 'https://h.example',
      token: const Secret('supersecret'),
    );
    // Interpolating it - the way a secret actually escapes, through an
    // error message somebody added in a hurry - yields the marker.
    expect('${fetcher.sawToken}', redactionMarker);
    expect(fetcher.sawToken!.expose(), 'supersecret');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_fetcher_test.dart`
Expected: FAIL — `ApiFetcher`, `FetchOutcome`, `jsonResponse` are not defined.

- [ ] **Step 3: Create the interface**

`packages/flutter_testsmith_engine/lib/src/validation/api_fetcher.dart`:

```dart
import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../secrets/secret_ref.dart';
import 'api_source.dart';

/// What a fetch produced.
///
/// Sealed rather than nullable, for the same reason validation
/// distinguishes skip from error: "it answered 401" and "nothing
/// answered" are different facts and need different words.
@immutable
sealed class FetchOutcome {
  const FetchOutcome();
}

final class FetchSucceeded extends FetchOutcome {
  const FetchSucceeded(this.payload);

  final ApiResponsePayload payload;
}

/// The request did not produce a usable response.
///
/// Always an **error** at the validation layer, never a failure: the
/// runner not being able to reach the backend says nothing about the
/// application.
final class FetchFailed extends FetchOutcome {
  const FetchFailed(this.reason);

  /// One actionable line. Never contains a header, a token, or a
  /// credential of any kind.
  final String reason;
}

/// Issues the request a screen's [ApiSource] describes.
///
/// An interface, mirroring the Figma client's `FigmaHttp`, so every test
/// in this milestone runs without a network. The `dart:io`
/// implementation lives in `flutter_testsmith_cli`, keeping `flutter_testsmith_engine` free of
/// transport.
abstract interface class ApiFetcher {
  /// [token] is resolved by the caller immediately before this call and
  /// is not retained afterwards.
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  });
}

/// Builds the payload a fetched response becomes.
///
/// Normalised into the protocol's own [ApiResponsePayload] so the
/// existing comparison validators need no change at all - they already
/// consume this type.
///
/// **Request headers are not carried.** The authorization header is the
/// one thing that must never reach a report, and the safest way to
/// guarantee that is for it never to enter the model. Response headers
/// are omitted for the same reason: a `set-cookie` is a credential.
ApiResponsePayload jsonResponse({
  required int? statusCode,
  required String? body,
  required int durationMs,
  String? error,
}) =>
    ApiResponsePayload(
      requestId: 'fetched',
      statusCode: statusCode,
      body: body,
      durationMs: durationMs,
      error: error,
    );
```

- [ ] **Step 4: Export it and run the test**

Add to the barrel:

```dart
export 'src/validation/api_fetcher.dart';
```

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_fetcher_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the `dart:io` implementation**

`packages/flutter_testsmith_cli/lib/src/http_api_fetcher.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Issues a screen's declared API request over real HTTP.
///
/// Every failure mode becomes a [FetchFailed] with one actionable line.
/// None of them names a header: the authorization header is exactly what
/// must not reach a log or a report, and an error message added in a
/// hurry is how it would.
class HttpApiFetcher implements ApiFetcher {
  const HttpApiFetcher({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    final Uri uri;
    try {
      uri = source.resolvedUri(resolvedBaseUrl);
    } on FormatException {
      return FetchFailed(
        '"$resolvedBaseUrl" with endpoint "${source.endpoint}" is not a '
        'usable URL',
      );
    }

    final client = HttpClient()..connectionTimeout = timeout;
    final watch = Stopwatch()..start();
    try {
      final request = await client.openUrl(source.method, uri);

      source.headers.forEach(request.headers.set);
      if (token != null) {
        // The one place the value is exposed. It goes straight into the
        // header and is not held afterwards.
        request.headers.set(HttpHeaders.authorizationHeader,
            'Bearer ${token.expose()}');
      }

      final body = source.body;
      if (body != null) {
        request.headers.contentType ??= ContentType.json;
        request.write(body);
      }

      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join();

      return FetchSucceeded(
        jsonResponse(
          statusCode: response.statusCode,
          body: text,
          durationMs: watch.elapsedMilliseconds,
        ),
      );
    } on TimeoutException {
      return FetchFailed(
        '${source.method} ${_safe(uri)} did not answer within '
        '${timeout.inSeconds}s',
      );
    } on SocketException catch (error) {
      return FetchFailed(
        '${source.method} ${_safe(uri)} could not be reached: '
        '${error.osError?.message ?? error.message}',
      );
    } on HttpException catch (error) {
      return FetchFailed(
        '${source.method} ${_safe(uri)} failed: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// The URL without its query, which can carry a token of its own.
  static String _safe(Uri uri) => uri.replace(query: '').toString();
}
```

- [ ] **Step 6: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS.

- [ ] **Step 7: Do NOT commit.**

---

## Task 6: Captured-preferred acquisition with fallback

The rule this milestone turns on: **captured traffic is always preferred; `apiSource:` is consulted only when the required captured response is unavailable — and never when it is ambiguous.**

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/validation/api_acquisition.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/validation/validators.dart` (`ValidationContext`)
- Modify: `packages/flutter_testsmith_cli/lib/src/flow_executor.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`
- Test: `packages/flutter_testsmith_engine/test/api_acquisition_test.dart`

**Interfaces:**
- Consumes: `ApiSource.requiredEndpoint`, `ApiFetcher`, `FetchOutcome`, `SecretResolver`, `ResponseResolver`, `ValidationContext`.
- Produces: sealed `ApiAcquisition` with `AcquiredFromCapture(payload, endpoint)`, `AcquiredFromFetch(payload, fallbackReason, endpoint)`, `AcquisitionUnavailable(reason)`, `AcquisitionAmbiguous(reason)`; `ApiAcquirer.acquire(...)`; `ValidationContext.acquired` (nullable, overrides `response`). Task 8 renders provenance.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/api_acquisition_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

class CountingFetcher implements ApiFetcher {
  CountingFetcher(this.outcome);
  final FetchOutcome outcome;
  int calls = 0;

  @override
  Future<FetchOutcome> fetch({
    required ApiSource source,
    required String resolvedBaseUrl,
    required Secret? token,
  }) async {
    calls++;
    return outcome;
  }
}

class FixedResolver implements SecretResolver {
  const FixedResolver(this._values);
  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => _values.containsKey(ref.name);

  @override
  Secret resolve(SecretRef ref) {
    final value = _values[ref.name];
    if (value == null) throw MissingSecretException(ref);
    return Secret(value);
  }
}

ScreenSession _screenWith(List<ApiExchange> exchanges) {
  final session = ScreenSession(
    screenId: '/product/details',
    enteredAt: DateTime.utc(2026, 9, 15),
  );
  for (final e in exchanges) {
    session.exchanges.add(e);
  }
  return session;
}

/// `ApiExchange` is immutable — the response goes in through the
/// constructor, not a cascade.
ApiExchange _exchange(String method, String path, String body) {
  final requestId = '$method$path$body';
  final at = DateTime.utc(2026, 9, 15);
  return ApiExchange(
    request: ApiRequestPayload(
      requestId: requestId,
      method: method,
      url: 'https://host.example$path',
    ),
    requestedAt: at,
    response: ApiResponsePayload(
      requestId: requestId,
      statusCode: 200,
      body: body,
      durationMs: 3,
    ),
    respondedAt: at,
  );
}

const _mappings = '''
screen: /product/details
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
  token: env:API_TOKEN
mappings:
  - target: product.price
    source: response.price
''';

void main() {
  test('captured traffic is preferred, and no request is issued', () async {
    final fetcher = CountingFetcher(
      FetchSucceeded(
        jsonResponse(statusCode: 200, body: '{"price": 999}', durationMs: 1),
      ),
    );
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      session: _screenWith([
        _exchange('GET', '/products/123', '{"price": 120}'),
      ]),
      history: const [],
      fetcher: fetcher,
      secrets: const FixedResolver({'API_TOKEN': 'x'}),
    );

    expect(acquisition, isA<AcquiredFromCapture>());
    expect((acquisition as AcquiredFromCapture).payload.readPath('price'), 120);
    expect(fetcher.calls, 0, reason: 'a fetch was issued despite a capture');
  });

  test('a fetch happens only when the capture is unavailable', () async {
    final fetcher = CountingFetcher(
      FetchSucceeded(
        jsonResponse(statusCode: 200, body: '{"price": 120}', durationMs: 1),
      ),
    );
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      // The screen called something else entirely.
      session: _screenWith([_exchange('GET', '/appconfig', '{}')]),
      history: const [],
      fetcher: fetcher,
      secrets: const FixedResolver({'API_TOKEN': 'x'}),
    );

    expect(acquisition, isA<AcquiredFromFetch>());
    final fetched = acquisition as AcquiredFromFetch;
    expect(fetched.payload.readPath('price'), 120);
    expect(fetched.fallbackReason, contains('/products/123'));
    expect(fetcher.calls, 1);
  });

  test('ambiguity never falls back to a fetch', () async {
    final fetcher = CountingFetcher(
      FetchSucceeded(
        jsonResponse(statusCode: 200, body: '{"price": 1}', durationMs: 1),
      ),
    );
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      session: _screenWith([
        _exchange('GET', '/products/123', '{"price": 120}'),
        _exchange('GET', '/products/123', '{"price": 140}'),
      ]),
      history: const [],
      fetcher: fetcher,
      secrets: const FixedResolver({'API_TOKEN': 'x'}),
    );

    expect(acquisition, isA<AcquisitionAmbiguous>());
    expect(fetcher.calls, 0,
        reason: 'a fetch silently answered a question the platform refuses');
    expect((acquisition as AcquisitionAmbiguous).reason, contains('2'));
  });

  test('a failed fetch is unavailable with the reason, not a fake pass',
      () async {
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      session: _screenWith(const []),
      history: const [],
      fetcher: CountingFetcher(
        const FetchFailed('the connection was refused'),
      ),
      secrets: const FixedResolver({'API_TOKEN': 'x'}),
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect((acquisition as AcquisitionUnavailable).reason,
        contains('refused'));
  });

  test('a non-2xx fetch is unavailable and names the status', () async {
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      session: _screenWith(const []),
      history: const [],
      fetcher: CountingFetcher(
        FetchSucceeded(
          jsonResponse(statusCode: 401, body: 'nope', durationMs: 1),
        ),
      ),
      secrets: const FixedResolver({'API_TOKEN': 'x'}),
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect((acquisition as AcquisitionUnavailable).reason, contains('401'));
  });

  test('a missing credential is unavailable and names the variable only',
      () async {
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(_mappings, source: 't'),
      session: _screenWith(const []),
      history: const [],
      fetcher: CountingFetcher(
        FetchSucceeded(jsonResponse(statusCode: 200, body: '{}', durationMs: 1)),
      ),
      secrets: const FixedResolver({}),
    );
    expect(acquisition, isA<AcquisitionUnavailable>());
    expect((acquisition as AcquisitionUnavailable).reason,
        contains('API_TOKEN'));
  });

  test('a screen with no apiSource is unchanged', () async {
    final acquisition = await const ApiAcquirer().acquire(
      mappings: MappingsFile.parse(
        'screen: /product/details\napi: GET /products/123\n',
        source: 't',
      ),
      session: _screenWith([
        _exchange('GET', '/products/123', '{"price": 120}'),
      ]),
      history: const [],
      fetcher: CountingFetcher(
        FetchSucceeded(jsonResponse(statusCode: 200, body: '{}', durationMs: 1)),
      ),
      secrets: const FixedResolver({}),
    );
    expect(acquisition, isA<AcquiredFromCapture>());
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_acquisition_test.dart`
Expected: FAIL — `ApiAcquirer` is not defined.

- [ ] **Step 3: Implement the acquirer**

`packages/flutter_testsmith_engine/lib/src/validation/api_acquisition.dart`:

```dart
import 'package:meta/meta.dart';
import 'package:flutter_testsmith_protocol/flutter_testsmith_protocol.dart';

import '../secrets/secret_ref.dart';
import '../session/screen_session.dart';
import 'api_fetcher.dart';
import 'api_source.dart';
import 'mappings.dart';
import 'response_source.dart';

/// Where a screen's response came from.
@immutable
sealed class ApiAcquisition {
  const ApiAcquisition();
}

/// The application's own traffic. The preferred answer, always.
final class AcquiredFromCapture extends ApiAcquisition {
  const AcquiredFromCapture({required this.payload, required this.endpoint});

  final ApiResponsePayload payload;
  final String endpoint;
}

/// A request the runner made, because the capture could not supply one.
///
/// A weaker claim than a capture, and the report says so: a
/// non-deterministic or stateful backend may answer the runner
/// differently from the application.
final class AcquiredFromFetch extends ApiAcquisition {
  const AcquiredFromFetch({
    required this.payload,
    required this.endpoint,
    required this.fallbackReason,
  });

  final ApiResponsePayload payload;
  final String endpoint;

  /// Why the capture did not supply it.
  final String fallbackReason;
}

/// Nothing to compare against. An **error**, never a failure.
final class AcquisitionUnavailable extends ApiAcquisition {
  const AcquisitionUnavailable(this.reason);

  final String reason;
}

/// Several captured responses matched and the declaration does not say
/// which.
///
/// Deliberately **not** a fallback trigger. Issuing a request and
/// preferring its answer would silently resolve a question the platform
/// elsewhere refuses to resolve, and would let the runner's own fetch
/// override two responses the application actually received.
final class AcquisitionAmbiguous extends ApiAcquisition {
  const AcquisitionAmbiguous(this.reason);

  final String reason;
}

/// Chooses a screen's response: capture first, a declared fetch second.
class ApiAcquirer {
  const ApiAcquirer();

  Future<ApiAcquisition> acquire({
    required MappingsFile? mappings,
    required ScreenSession session,
    required List<ScreenSession> history,
    required ApiFetcher fetcher,
    required SecretResolver secrets,
  }) async {
    if (mappings == null) {
      return const AcquisitionUnavailable('no mappings for this screen');
    }

    // 1. usesResponseFrom: - the most explicit declaration, resolved
    //    across the whole session by the existing resolver.
    final declared = mappings.usesResponseFrom;
    if (declared != null) {
      final resolution = const ResponseResolver().resolve(
        source: declared,
        history: history.isEmpty ? [session] : history,
        renderedScreenEnteredAt: session.enteredAt,
      );
      switch (resolution) {
        case ResponseResolved(:final response):
          return AcquiredFromCapture(
            payload: response.payload,
            endpoint: response.endpoint,
          );
        case ResponseAmbiguous(:final reason):
          return AcquisitionAmbiguous(reason);
        case ResponseUnavailable(:final reason):
          return _fallback(mappings, fetcher, secrets, reason);
      }
    }

    // 2. api: - existing behaviour, first match on this screen. Left
    //    exactly as it is: tightening it would turn currently-passing
    //    runs into errors.
    final endpoint = ApiEndpoint.tryParse(mappings.api);
    if (endpoint != null) {
      final match = _firstMatch(session, endpoint);
      if (match != null) return match;
      return _fallback(
        mappings,
        fetcher,
        secrets,
        'the mappings name "$endpoint", which this screen did not call. '
        'It called: ${_called(session)}.',
      );
    }

    // 3. apiSource: - new, so it gets `only` semantics from the outset.
    final source = mappings.apiSource;
    if (source != null) {
      final base = _resolveBase(source, secrets);
      if (base == null) {
        return AcquisitionUnavailable(
          'the apiSource baseUrl "${source.baseUrl}" resolved to nothing. '
          'Set that environment variable, or put it in a .env file that is '
          'not committed.',
        );
      }
      final required = source.requiredEndpoint(base);
      final matches = _allMatches(session, required);
      if (matches.length > 1) {
        return AcquisitionAmbiguous(
          'the application called $required ${matches.length} times, so '
          'which one this screen is showing is ambiguous. Add '
          '`usesResponseFrom:` with `occurrence: first` or '
          '`occurrence: last` to say which.',
        );
      }
      if (matches.length == 1) {
        return AcquiredFromCapture(
          payload: matches.single.response!,
          endpoint: '$required',
        );
      }
      return _fallback(
        mappings,
        fetcher,
        secrets,
        'the application did not call $required on this screen. '
        'It called: ${_called(session)}.',
      );
    }

    // 4. Nothing declared - existing behaviour.
    for (final exchange in session.exchanges) {
      final payload = exchange.response;
      if (payload != null) {
        return AcquiredFromCapture(
          payload: payload,
          endpoint: '${exchange.request.method} ${exchange.request.path}',
        );
      }
    }
    return const AcquisitionUnavailable(
      'no API response was captured for this screen, so nothing could be '
      'compared',
    );
  }

  /// Issues the declared request, if one is declared.
  Future<ApiAcquisition> _fallback(
    MappingsFile mappings,
    ApiFetcher fetcher,
    SecretResolver secrets,
    String why,
  ) async {
    final source = mappings.apiSource;
    if (source == null) return AcquisitionUnavailable(why);

    final base = _resolveBase(source, secrets);
    if (base == null) {
      return AcquisitionUnavailable(
        '$why The declared apiSource could not be used either: its baseUrl '
        '"${source.baseUrl}" resolved to nothing.',
      );
    }

    Secret? token;
    final ref = source.token;
    if (ref != null) {
      if (!secrets.isPresent(ref)) {
        return AcquisitionUnavailable(
          '$why The declared apiSource could not be used either: $ref '
          'resolved to nothing. Set the ${ref.name} environment variable, '
          'or put it in a .env file that is not committed.',
        );
      }
      token = secrets.resolve(ref);
    }

    final outcome = await fetcher.fetch(
      source: source,
      resolvedBaseUrl: base,
      token: token,
    );

    switch (outcome) {
      case FetchFailed(:final reason):
        return AcquisitionUnavailable(
          '$why The declared apiSource could not be used either: $reason.',
        );
      case FetchSucceeded(:final payload):
        if (!payload.isSuccess) {
          return AcquisitionUnavailable(
            '$why The declared apiSource answered '
            '${payload.statusCode ?? payload.error}, so there is nothing '
            'to compare against.',
          );
        }
        return AcquiredFromFetch(
          payload: payload,
          endpoint: '${source.method} ${source.endpoint}',
          fallbackReason: why,
        );
    }
  }

  /// Resolves a baseUrl that may be an `env:` reference.
  ///
  /// Not a secret - it is a URL, and a report may name it - but read
  /// through the same mechanism so a missing one fails the same way.
  static String? _resolveBase(ApiSource source, SecretResolver secrets) {
    final raw = source.baseUrl;
    if (!raw.startsWith('${SecretRef.envScheme}:')) return raw;
    final ref = SecretRef(
      scheme: SecretRef.envScheme,
      name: raw.substring(SecretRef.envScheme.length + 1),
    );
    if (!secrets.isPresent(ref)) return null;
    return secrets.resolve(ref).expose();
  }

  static AcquiredFromCapture? _firstMatch(
    ScreenSession session,
    ApiEndpoint endpoint,
  ) {
    for (final exchange in session.exchanges) {
      final payload = exchange.response;
      if (payload == null) continue;
      if (endpoint.matches(exchange.request.method, exchange.request.path)) {
        return AcquiredFromCapture(payload: payload, endpoint: '$endpoint');
      }
    }
    return null;
  }

  static List<ApiExchange> _allMatches(
    ScreenSession session,
    ApiEndpoint endpoint,
  ) =>
      [
        for (final exchange in session.exchanges)
          if (exchange.response != null &&
              endpoint.matches(exchange.request.method, exchange.request.path))
            exchange,
      ];

  static String _called(ScreenSession session) {
    final seen = <String>[];
    for (final exchange in session.exchanges) {
      if (exchange.response == null) continue;
      final line = '${exchange.request.method} ${exchange.request.path}';
      if (!seen.contains(line)) seen.add(line);
    }
    return seen.isEmpty ? 'nothing' : seen.join(', ');
  }
}
```

- [ ] **Step 4: Export and run the test**

Add to the barrel:

```dart
export 'src/validation/api_acquisition.dart';
```

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/api_acquisition_test.dart`
Expected: PASS, 7 tests.

- [ ] **Step 5: Let `ValidationContext` accept an acquisition**

In `validators.dart`, add the field and let it take precedence:

```dart
  /// How this screen's response was obtained, when the runner resolved
  /// it ahead of validation.
  ///
  /// Null keeps the pre-E-06 behaviour exactly: `response` falls back to
  /// reading the captured exchanges itself.
  final ApiAcquisition? acquired;
```

with `this.acquired,` in the constructor, and change the `response` getter to consult it first:

```dart
  ApiResponsePayload? get response {
    final resolved = acquired;
    if (resolved != null) {
      return switch (resolved) {
        AcquiredFromCapture(:final payload) => payload,
        AcquiredFromFetch(:final payload) => payload,
        AcquisitionUnavailable() || AcquisitionAmbiguous() => null,
      };
    }

    // ... existing body unchanged ...
  }
```

And extend `ApiToUiValidator._noResponseMessage` to prefer the acquisition's reason:

```dart
  static String _noResponseMessage(ValidationContext context) {
    switch (context.acquired) {
      case AcquisitionUnavailable(:final reason):
        return reason;
      case AcquisitionAmbiguous(:final reason):
        return reason;
      case AcquiredFromCapture() || AcquiredFromFetch() || null:
        break;
    }

    // ... existing body unchanged ...
  }
```

Add `import 'api_acquisition.dart';` to `validators.dart`.

- [ ] **Step 6: Add provenance to the evidence chain**

In `ApiToUiValidator._check`, extend the `chain` list with the provenance of the acquisition, immediately before `Evidence(kind: 'apiPath', ...)`:

```dart
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
```

- [ ] **Step 7: Wire it into the executor**

In `flow_executor.dart`, add fields to the constructor:

```dart
  /// Issues a screen's declared `apiSource:` request, when the capture
  /// could not supply the response. Never called otherwise.
  final ApiFetcher apiFetcher;

  /// Resolves `env:` references for API and Figma credentials.
  final SecretResolver secrets;
```

with `required this.apiFetcher,` and `required this.secrets,` in the parameter list.

In `_validate`, immediately before building the `ValidationContext`:

```dart
    // Capture first. A fetch is issued only if this comes back with
    // nothing, so a fully-instrumented run makes no outbound request of
    // its own.
    final acquired = await const ApiAcquirer().acquire(
      mappings: mappings[screenId],
      session: screenSession,
      history: correlation.sessions,
      fetcher: apiFetcher,
      secrets: secrets,
    );
```

and pass `acquired: acquired,` to the `ValidationContext` constructor.

In `run_command.dart` and `suite_runner.dart`, pass the two new arguments where `FlowExecutor(` is constructed:

```dart
      apiFetcher: const HttpApiFetcher(),
      secrets: EnvSecretResolver(dotenv: dotenv),
```

using the `DotEnv` each command already loads. Add the imports for `HttpApiFetcher` and `EnvSecretResolver`.

- [ ] **Step 8: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS. Existing tests constructing `ValidationContext` are unaffected — `acquired` is optional and null preserves the old path exactly.

- [ ] **Step 9: Do NOT commit.**

---

## Task 7: Resolve `figmaSource:` at run time

**Files:**
- Create: `packages/flutter_testsmith_cli/lib/src/figma_source_resolver.dart`
- Modify: `packages/flutter_testsmith_cli/lib/src/project_config.dart`
- Modify: `packages/flutter_testsmith_cli/lib/src/commands/run_command.dart`, `lib/src/suite_runner.dart`
- Test: `packages/flutter_testsmith_cli/test/figma_source_resolver_test.dart`

**Interfaces:**
- Consumes: `FigmaSource`, `SecretResolver`, `FigmaClient`, `FigmaHttp`, `FigmaNormaliser`, `FigmaNodeMapping`, `FigmaTarget`.
- Produces: `FigmaResolution` sealed — `FigmaResolved(FigmaScreenSpec spec)`, `FigmaResolutionFailed(String reason)`; `resolveFigmaSources({required Directory project, required Map<String, MappingsFile> mappings, required SecretResolver secrets, FigmaHttp? http}) -> Future<(Map<String, FigmaScreenSpec>, Map<String, String>)>` returning specs by screen and failures by screen.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_cli/test/figma_source_resolver_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:figma_client/figma_client.dart';
import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/figma_source_resolver.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

class StubHttp implements FigmaHttp {
  StubHttp(this.status, this.body);
  final int status;
  final String body;
  int calls = 0;
  String? sawToken;

  @override
  Future<FigmaHttpResponse> get(
    String url,
    Map<String, String> headers,
  ) async {
    calls++;
    sawToken = headers['X-Figma-Token'];
    return FigmaHttpResponse(status: status, body: body);
  }
}

class FixedResolver implements SecretResolver {
  const FixedResolver(this._values);
  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => _values.containsKey(ref.name);

  @override
  Secret resolve(SecretRef ref) {
    final v = _values[ref.name];
    if (v == null) throw MissingSecretException(ref);
    return Secret(v);
  }
}

/// A frame with one 100x40 child, enough to normalise.
const _frame = '''
{"nodes":{"909:1":{"document":{
  "id":"909:1","name":"Login","type":"FRAME",
  "absoluteBoundingBox":{"x":0,"y":0,"width":402,"height":800},
  "children":[{"id":"909:133","name":"Add Button","type":"FRAME",
    "absoluteBoundingBox":{"x":20,"y":100,"width":100,"height":40}}]
}}}}''';

Directory _project(String mappingYaml) {
  final dir = Directory.systemTemp.createTempSync('e06figma');
  Directory('${dir.path}/figma').createSync(recursive: true);
  File('${dir.path}/figma/login.mapping.yaml').writeAsStringSync(mappingYaml);
  return dir;
}

void main() {
  test('a declared figmaSource is fetched and normalised', () async {
    final project = _project('screen: /login\nnodes:\n  "909:133": login.google_button\n');
    addTearDown(() => project.deleteSync(recursive: true));
    final http = StubHttp(200, _frame);

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {
        '/login': MappingsFile.parse('''
screen: /login
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''', source: 't'),
      },
      secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_x'}),
      http: http,
    );

    expect(failures, isEmpty);
    expect(specs['/login']!.figmaName, 'Login');
    expect(specs['/login']!.bySemanticId('login.google_button'), isNotNull);
    expect(http.sawToken, 'figd_x');
  });

  test('a rejected token becomes a failure that never echoes it', () async {
    final project = _project('screen: /login\nnodes: {}\n');
    addTearDown(() => project.deleteSync(recursive: true));

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {
        '/login': MappingsFile.parse('''
screen: /login
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''', source: 't'),
      },
      secrets: const FixedResolver({'FIGMA_TOKEN': 'figd_secret_value'}),
      http: StubHttp(403, '{}'),
    );

    expect(specs, isEmpty);
    expect(failures['/login'], contains('403'));
    expect(failures['/login'], isNot(contains('figd_secret_value')));
  });

  test('a missing token is a failure naming only the variable', () async {
    final project = _project('screen: /login\nnodes: {}\n');
    addTearDown(() => project.deleteSync(recursive: true));

    final (_, failures) = await resolveFigmaSources(
      project: project,
      mappings: {
        '/login': MappingsFile.parse('''
screen: /login
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/login.mapping.yaml
''', source: 't'),
      },
      secrets: const FixedResolver({}),
      http: StubHttp(200, _frame),
    );

    expect(failures['/login'], contains('FIGMA_TOKEN'));
  });

  test('a missing mapping file is a failure, not a silent skip', () async {
    final project = Directory.systemTemp.createTempSync('e06figma');
    addTearDown(() => project.deleteSync(recursive: true));

    final (_, failures) = await resolveFigmaSources(
      project: project,
      mappings: {
        '/login': MappingsFile.parse('''
screen: /login
figmaSource:
  url: https://figma.com/design/abc/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/absent.mapping.yaml
''', source: 't'),
      },
      secrets: const FixedResolver({'FIGMA_TOKEN': 'x'}),
      http: StubHttp(200, _frame),
    );

    expect(failures['/login'], contains('absent.mapping.yaml'));
  });

  test('a screen with no figmaSource is not touched', () async {
    final project = Directory.systemTemp.createTempSync('e06figma');
    addTearDown(() => project.deleteSync(recursive: true));
    final http = StubHttp(200, _frame);

    final (specs, failures) = await resolveFigmaSources(
      project: project,
      mappings: {'/login': MappingsFile.parse('screen: /login', source: 't')},
      secrets: const FixedResolver({}),
      http: http,
    );

    expect(specs, isEmpty);
    expect(failures, isEmpty);
    expect(http.calls, 0);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_cli/test/figma_source_resolver_test.dart`
Expected: FAIL — `figma_source_resolver.dart` does not exist.

- [ ] **Step 3: Implement the resolver**

`packages/flutter_testsmith_cli/lib/src/figma_source_resolver.dart`:

```dart
import 'dart:io';

import 'package:figma_client/figma_client.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Resolves every screen's declared `figmaSource:` into a normalised
/// specification.
///
/// Through the **existing** client and its on-disk cache, so two runs of
/// the same test see the same design. Figma rate-limits, and a milestone
/// named for determinism should not make a design able to change between
/// two steps of one run.
///
/// Returns the specs it resolved and, separately, the reason each screen
/// that declared one failed. A failure is surfaced rather than swallowed:
/// a declared design that quietly did not load would make the Figma
/// dimension skip, which reads as "not configured" when it is in fact
/// "configured and broken".
Future<(Map<String, FigmaScreenSpec>, Map<String, String>)>
    resolveFigmaSources({
  required Directory project,
  required Map<String, MappingsFile> mappings,
  required SecretResolver secrets,
  FigmaHttp? http,
}) async {
  final specs = <String, FigmaScreenSpec>{};
  final failures = <String, String>{};

  for (final entry in mappings.entries) {
    final source = entry.value.figmaSource;
    if (source == null) continue;

    final screen = entry.key;

    if (!secrets.isPresent(source.token)) {
      failures[screen] = 'the Figma token ${source.token} resolved to '
          'nothing. Set the ${source.token.name} environment variable, or '
          'put it in a .env file that is not committed.';
      continue;
    }

    final mappingFile = File('${project.path}/${source.mappingPath}');
    if (!mappingFile.existsSync()) {
      failures[screen] = 'the node mapping "${source.mappingPath}" does not '
          'exist. Structural comparison maps by node id, never by layer '
          'name; run `testsmith figma pull --write-mapping-template` to get a '
          'starting point.';
      continue;
    }

    final FigmaTarget target;
    try {
      target = FigmaTarget.parseUrl(source.url);
    } on FormatException catch (error) {
      failures[screen] = error.message;
      continue;
    }

    final FigmaNodeMapping nodeMapping;
    try {
      nodeMapping = FigmaNodeMapping.parse(
        await mappingFile.readAsString(),
        source: mappingFile.path,
      );
    } on FormatException catch (error) {
      failures[screen] = error.message;
      continue;
    }

    // Resolved immediately before the request and not retained.
    final token = secrets.resolve(source.token);
    final client = FigmaClient(
      token: token.expose(),
      http: http,
      cacheDirectory: Directory('${project.path}/figma/.cache'),
    );

    try {
      final raw = await client.fetchNode(
        fileKey: target.fileKey,
        nodeId: target.nodeId,
      );
      specs[screen] = const FigmaNormaliser().normalise(
        raw,
        nodeId: target.nodeId,
        screen: screen,
        mapping: nodeMapping,
      );
    } on FigmaException catch (error) {
      // The client's own message. It names the file key and the status
      // and has never echoed the token.
      failures[screen] = error.message;
    }
  }

  return (specs, failures);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_cli/test/figma_source_resolver_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Give `figmaSource:` precedence over the on-disk spec**

In `project_config.dart`, add a merge helper:

```dart
/// Combines on-disk specs with those a mappings file declares.
///
/// A declared `figmaSource:` **wins** for its screen. A stale
/// `figma/<screen>.json` silently shadowing a URL somebody declared is
/// exactly the quiet wrongness this platform exists to avoid, so which
/// one was used is reported.
Map<String, FigmaScreenSpec> mergeFigmaSpecs({
  required Map<String, FigmaScreenSpec> fromDisk,
  required Map<String, FigmaScreenSpec> fromSource,
  void Function(String)? onNote,
}) {
  final merged = {...fromDisk};
  for (final entry in fromSource.entries) {
    if (fromDisk.containsKey(entry.key)) {
      onNote?.call(
        '  figma: "${entry.key}" uses the declared figmaSource, not the '
        'spec on disk',
      );
    }
    merged[entry.key] = entry.value;
  }
  return merged;
}
```

- [ ] **Step 6: Wire it into the commands**

In `run_command.dart` and `suite_runner.dart`, after `loadFigmaSpecs(...)` and before constructing the `FlowExecutor`:

```dart
    final (declaredSpecs, figmaFailures) = await resolveFigmaSources(
      project: project,
      mappings: mappings,
      secrets: secrets,
    );
    final figmaSpecs = mergeFigmaSpecs(
      fromDisk: diskSpecs,
      fromSource: declaredSpecs,
      onNote: output.line,
    );
    for (final entry in figmaFailures.entries) {
      output.line(output.red('  figma: ${entry.key}: ${entry.value}'));
    }
```

A screen in `figmaFailures` has no spec, so `FigmaStructureValidator` will report its own skip. To make that an ERROR instead — a declared design that could not be loaded is not "not configured" — pass the failures into `FlowExecutor` and emit, in `_validate`, before the validators run:

```dart
    final figmaFailure = figmaFailures[screenId];
```

and in the results list:

```dart
      if (step.runsFigma && figmaFailure != null)
        ValidationResult.error(
          validatorId: 'figma-source',
          dimension: ValidationDimension.figma,
          message: figmaFailure,
        )
      else if (step.runsFigma)
        ...runValidator(const FigmaStructureValidator(), context),
```

Add `final Map<String, String> figmaFailures;` to `FlowExecutor`, defaulting to `const {}`.

- [ ] **Step 7: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS.

- [ ] **Step 8: Do NOT commit.**

---

## Task 8: Report the dimensions

**Files:**
- Modify: `packages/flutter_testsmith_engine/lib/src/reporting/html_reporter.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/reporting/suite_result.dart`
- Modify: `packages/flutter_testsmith_cli/lib/src/flow_executor.dart`
- Test: `packages/flutter_testsmith_engine/test/dimension_reporting_test.dart`

**Interfaces:**
- Consumes: `RunResult.dimensions`, `RunResult.overall`.
- Produces: an HTML block and a terminal block. `SuiteTestResult.dimensions` (nullable map) for suite reports.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/dimension_reporting_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

RunResult _run(List<ValidationResult> results) => RunResult(
      flowName: 'product_details',
      appId: 'com.example.ecommerce_app',
      device: 'emulator-5554',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: const Duration(seconds: 3),
      steps: const [
        StepOutcome(
          description: 'launch the app',
          status: StepStatus.ok,
          durationMs: 10,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport(results),
        ),
      ],
    );

void main() {
  test('the report shows every dimension, including the skipped ones', () {
    final html = const HtmlReporter().render(
      _run([
        ValidationResult.pass(
          validatorId: 'api-to-ui',
          message: 'response.price matches product.price.text',
          dimension: ValidationDimension.api,
        ),
        ValidationResult.fail(
          validatorId: 'figma-geometry',
          message: 'width is 282.0px but the design specifies 322.0px',
          dimension: ValidationDimension.figma,
        ),
      ]).toJson(),
    );

    expect(html, contains('API'));
    expect(html, contains('FIGMA'));
    expect(html, contains('UI'));
    expect(html, contains('VISUAL'));
    expect(html, contains('OVERALL'));
    // The failure's own sentence reaches the block, not just a colour.
    expect(html, contains('322.0px'));
  });

  test('a passing dimension is not rendered as the overall verdict', () {
    final json = _run([
      ValidationResult.pass(
        validatorId: 'api-to-ui',
        message: 'matches',
        dimension: ValidationDimension.api,
      ),
      ValidationResult.fail(
        validatorId: 'figma-geometry',
        message: 'differs',
        dimension: ValidationDimension.figma,
      ),
    ]).toJson();

    expect((json['dimensions']! as Map)['api'], containsPair('status', 'pass'));
    expect(json['overall'], 'fail');
    expect(json['passed'], isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/dimension_reporting_test.dart`
Expected: FAIL — the HTML has no dimension block.

- [ ] **Step 3: Render the block in HTML**

In `html_reporter.dart`, add a method and call it at the top of the body, above the per-screen sections:

```dart
  /// The four dimensions and the overall verdict, above everything else.
  ///
  /// First, deliberately. A reader who sees only a green header cannot
  /// tell which dimensions that verdict speaks for, and a dimension that
  /// was never checked reads as evidence when it is absent from the page.
  String _dimensions(Map<String, Object?> json) {
    final dimensions = json['dimensions'] as Map<String, Object?>?;
    if (dimensions == null) return '';

    final rows = StringBuffer();
    for (final key in const ['ui', 'api', 'figma', 'visual']) {
      final entry = dimensions[key] as Map<String, Object?>?;
      if (entry == null) continue;
      final status = '${entry['status']}';
      final reason = entry['reason'];
      rows.write(
        '<tr class="dim dim-$status">'
        '<th>${key.toUpperCase()}</th>'
        '<td class="status">${status.toUpperCase()}</td>'
        '<td class="reason">${reason == null ? '' : _escape('$reason')}</td>'
        '</tr>',
      );
    }

    final overall = '${json['overall']}';
    rows.write(
      '<tr class="dim dim-overall dim-$overall">'
      '<th>OVERALL</th>'
      '<td class="status">${overall.toUpperCase()}</td>'
      '<td></td></tr>',
    );

    return '<table class="dimensions">$rows</table>';
  }
```

Reuse whatever HTML-escaping helper the file already defines; if it is named differently from `_escape`, use that name.

Add to the stylesheet string in the same file:

```css
.dimensions { border-collapse: collapse; margin: 1rem 0; width: 100%; }
.dimensions th { text-align: left; padding: .4rem .8rem; width: 8rem; }
.dimensions td.status { font-weight: 700; padding: .4rem .8rem; width: 6rem; }
.dimensions td.reason { padding: .4rem .8rem; color: #555; }
.dim-pass td.status { color: #1b7f3b; }
.dim-fail td.status { color: #b3261e; }
.dim-error td.status { color: #8a4b00; }
.dim-skip td.status { color: #666; }
.dim-overall { border-top: 2px solid #333; }
```

- [ ] **Step 4: Print the block in the terminal**

In `flow_executor.dart`, at the end of `run()` just before returning the `RunResult`, add:

```dart
    final result = RunResult(/* ... existing arguments ... */);

    log('');
    for (final entry in result.dimensions.entries) {
      final verdict = entry.value;
      final name = entry.key.wire.toUpperCase().padRight(8);
      log('  $name ${verdict.status.wire.toUpperCase()}'
          '${verdict.reason == null ? '' : '   ${verdict.reason}'}');
    }
    log('  ${'OVERALL'.padRight(8)} ${result.overall.wire.toUpperCase()}');

    return result;
```

- [ ] **Step 5: Carry dimensions on the suite result**

In `suite_result.dart`, add to `SuiteTestResult`:

```dart
  /// The per-dimension verdicts of this test's run, when it produced one.
  ///
  /// Carried rather than re-derived, so a suite report cannot disagree
  /// with the run report it links to.
  Map<ValidationDimension, DimensionVerdict>? get dimensions =>
      run?.dimensions;
```

with `import '../validation/validation_dimension.dart';` and `import 'dimension_verdict.dart';`.

- [ ] **Step 6: Run the tests**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/dimension_reporting_test.dart`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test && dart analyze --fatal-infos`
Expected: PASS. `reporting_test.dart` and `suite_report_test.dart` may need their `resultSchemaVersion` assertions updated if Task 3 did not already do so.

- [ ] **Step 8: Do NOT commit.**

---

## Task 9: Prove the credentials cannot leak

**Files:**
- Create: `packages/flutter_testsmith_engine/test/e06_credential_leakage_test.dart`
- Test only. No production change expected — if one is needed, the leak is real and this task found it.

**Interfaces:**
- Consumes: everything from Tasks 4–8.

- [ ] **Step 1: Write the test**

Create `packages/flutter_testsmith_engine/test/e06_credential_leakage_test.dart`:

```dart
import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const _apiToken = 'sk-live-THIS-MUST-NEVER-APPEAR';
const _figmaToken = 'figd-THIS-MUST-NEVER-APPEAR';

void _assertClean(String text, String where) {
  expect(text, isNot(contains(_apiToken)), reason: '$where leaked the API token');
  expect(text, isNot(contains(_figmaToken)),
      reason: '$where leaked the Figma token');
}

void main() {
  test('the sentinel check can actually fail', () {
    // Without this, every assertion below would pass on an empty string
    // and prove nothing.
    expect(
      () => _assertClean('prefix $_apiToken suffix', 'canary'),
      throwsA(isA<TestFailure>()),
    );
  });

  test('a mappings file holds references, never values', () {
    final file = MappingsFile.parse('''
screen: /product/details
apiSource:
  baseUrl: https://host.example
  method: GET
  endpoint: /products/123
  token: env:EXAMPLE_API_TOKEN
figmaSource:
  url: https://figma.com/design/abc/F?node-id=1-2
  token: env:FIGMA_TOKEN
  mapping: figma/p.mapping.yaml
''', source: 't');

    expect('${file.apiSource!.token}', 'env:EXAMPLE_API_TOKEN');
    expect('${file.figmaSource!.token}', 'env:FIGMA_TOKEN');
    _assertClean('${file.apiSource} ${file.figmaSource}', 'toString');
  });

  test('a resolved secret renders as the marker under interpolation', () {
    const secret = Secret(_apiToken);
    _assertClean('the request failed with $secret', 'interpolation');
    expect('$secret', redactionMarker);
  });

  test('a fetched payload carries no headers into result.json', () {
    final payload = jsonResponse(
      statusCode: 200,
      body: '{"price": 120}',
      durationMs: 4,
    );
    _assertClean(jsonEncode(payload.toJson()), 'ApiResponsePayload');
    expect(payload.headers, isEmpty);
  });

  test('result.json and report.html are clean end to end', () {
    final run = RunResult(
      flowName: 'product_details',
      appId: 'com.example.ecommerce_app',
      device: 'emulator-5554',
      startedAt: DateTime.utc(2026, 9, 15),
      duration: const Duration(seconds: 2),
      steps: const [
        StepOutcome(
          description: 'launch the app',
          status: StepStatus.ok,
          durationMs: 5,
        ),
      ],
      screens: [
        ScreenResult(
          screenId: '/product/details',
          report: ValidationReport([
            ValidationResult.pass(
              validatorId: 'api-to-ui',
              message: 'response.price matches product.price.text',
              dimension: ValidationDimension.api,
              evidence: const [
                Evidence(kind: 'responseProvenance', reference: 'fetched'),
                Evidence(
                  kind: 'fallbackReason',
                  reference: 'the application did not call GET /products/123',
                ),
              ],
            ),
          ]),
        ),
      ],
    );

    final json = jsonEncode(run.toJson());
    _assertClean(json, 'result.json');
    _assertClean(const HtmlReporter().render(run.toJson()), 'report.html');
  });

  test('a missing secret names the variable and nothing around it', () {
    final ref = SecretRef.parse('env:EXAMPLE_API_TOKEN', source: 't');
    final message = MissingSecretException(ref).toString();
    expect(message, contains('EXAMPLE_API_TOKEN'));
    _assertClean(message, 'MissingSecretException');
  });
}
```

- [ ] **Step 2: Run it**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/e06_credential_leakage_test.dart`
Expected: PASS, 6 tests. **If any assertion fails, a credential really can escape — fix the production code, not the test.**

- [ ] **Step 3: Run the pre-existing leakage tests too**

Run: `cd /d/Repositories/flutter-ai-test-platform && dart test packages/flutter_testsmith_engine/test/report_leakage_test.dart packages/flutter_testsmith_engine/test/auth_leakage_test.dart integrations/figma_client/test/token_redaction_test.dart`
Expected: PASS, unchanged.

- [ ] **Step 4: Do NOT commit.**

---

## Task 10: Demonstrate, regress, document

**Files:**
- Create: `examples/ecommerce_app/tests/product_three_way.yaml`
- Modify: `examples/ecommerce_app/mappings/product_details.yaml`
- Create: `docs/E-06_UI_API_FIGMA_VALIDATION.md`
- Modify: `docs/evidence/api_to_ui_matrix.md` (regenerated)

- [ ] **Step 1: Add the declarations to the example's mappings**

Append to `examples/ecommerce_app/mappings/product_details.yaml`:

```yaml
# Where the runner may fetch this screen's response if the application's
# own traffic did not supply it. A fallback, never the first choice: a
# fully-instrumented run issues no request of its own.
apiSource:
  baseUrl: env:EXAMPLE_MOCK_BASE
  method: GET
  endpoint: /products/123
  # No token: the fixture server needs none. A real backend would name
  # one here as `token: env:EXAMPLE_API_TOKEN`.

# The design this screen is validated against, declared here rather than
# pulled to disk beforehand. The frame is the real one this repository
# was built against.
figmaSource:
  url: https://www.figma.com/design/<redacted>/App?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/product_details.mapping.yaml
```

- [ ] **Step 2: Write the demonstration flow**

`examples/ecommerce_app/tests/product_three_way.yaml`:

```yaml
appId: com.example.ecommerce_app
flow: product_three_way

# The user writes this. Nothing generates it, and nothing rewrites it.
steps:
  - launchApp
  - waitForSettle
  - tap: { id: login.submit }
  - expectScreen: { id: /home }
  - waitForSettle
  - tap: { id: home.open_product }
  - expectScreen: { id: /product/details }
  - waitForSettle

  # One step. API, UI, rules, Figma and visual each report separately.
  - validateScreen
```

- [ ] **Step 3: Run it and capture the PASS**

```bash
cd /d/Repositories/flutter-ai-test-platform
export EXAMPLE_MOCK_BASE=http://127.0.0.1:8787
dart run packages/flutter_testsmith_cli/bin/testsmith.dart run \
  examples/ecommerce_app/tests/product_three_way.yaml 2>&1 | tee /tmp/e06-pass.txt
```

Expected, at the end of the output:

```
  UI       PASS
  API      PASS
  FIGMA    PASS
  VISUAL   PASS
  OVERALL  PASS
```

Record the verbatim output. If FIGMA reports ERROR because `FIGMA_TOKEN` is unset, that is the correct behaviour — export a token and re-run, and if none is available, record the ERROR verbatim and say so rather than editing the expectation.

- [ ] **Step 4: Demonstrate the deliberate failure**

Use the existing `product_missing_price` style fixture mechanism. Add a flow that names a fixture whose price disagrees with what the UI renders:

```bash
cd /d/Repositories/flutter-ai-test-platform
sed -i 's/^flow: product_three_way$/flow: product_three_way_defect/' /dev/null # no-op guard
```

Create `examples/ecommerce_app/tests/product_three_way_defect.yaml` as a copy of Step 2's flow with `fixture: product_large_values` added under `flow:`, then seed the defect exactly as the existing `api_to_ui_matrix.md` row "DEFECT price off by 400" already does, and run:

```bash
dart run packages/flutter_testsmith_cli/bin/testsmith.dart run \
  examples/ecommerce_app/tests/product_three_way_defect.yaml 2>&1 | tee /tmp/e06-fail.txt
```

Expected:

```
  UI       PASS
  API      FAIL     product.price.text does not match response.price. ...
  FIGMA    PASS
  VISUAL   PASS
  OVERALL  FAIL
```

The point to verify in the output: **FIGMA and UI still read PASS**, and OVERALL is FAIL. A passing dimension did not hide the failing one, and the failing one did not contaminate the others.

- [ ] **Step 5: Run the full regression**

```bash
cd /d/Repositories/flutter-ai-test-platform
dart test 2>&1 | tail -30
dart analyze --fatal-infos
dart run scripts/package_boundaries.dart
git diff --stat docs/evidence/
```

Expected: all tests pass; analyzer clean; package boundaries hold; the evidence matrices either unchanged or changed only in ways you can explain. **A changed row that you cannot explain is a regression — stop and investigate rather than regenerating over it.**

- [ ] **Step 6: Write the milestone document**

Create `docs/E-06_UI_API_FIGMA_VALIDATION.md` covering, in this order: architecture; the user-written test definition; API input and authentication; API response acquisition including the captured-preferred rule and its fallback table; the Figma Dev URL and token; Figma data acquisition; UI evidence; API→UI mappings; Figma→UI mappings; the deterministic comparison rules and where tolerances live; the result model; PASS/FAIL/ERROR/SKIP semantics; credential handling; failure handling; the `examples/ecommerce_app` demonstration with the verbatim output from Steps 3 and 4; and known limitations.

It must state plainly that the ExternalApp demonstration of §15 was **not** performed, and why.

- [ ] **Step 7: Write the acceptance matrix**

Append to the document a table of all thirty-eight acceptance criteria with MET / NOT MET and, for each MET, the test or the command that shows it. The five ExternalApp criteria are NOT MET.

- [ ] **Step 8: Do NOT commit. Report to the user and wait for approval.**

Per E-06 §21 and the Global Constraints: report all implementation and validation results, then wait for explicit approval before any commit. Never push.

---

## Self-Review

**Spec coverage:** §1 dimensions → Tasks 2, 3. §2 principle → Task 3. §3.1 which dimensions → Task 2 Step 3. §3.2 classification table → Task 2 Steps 6–8. §3.3 rules rationale → Task 2 Step 6 comment. §3.4 aggregation → Task 3 Step 3. §3.5 computed rollup + equivalence → Task 3 Steps 4, 1. §3.6 reported shape → Task 8. §4.1 captured preferred → Task 6 Step 1 test 1. §4.2 matching table → Task 6 Step 3, all four rows. §4.3 fallback rule incl. no-fetch-on-ambiguous → Task 6 Step 1 test 3. §4.4 provenance → Task 6 Step 6. §4.5 declaration → Task 4. §4.6 fetch and security → Tasks 5, 9. §5.1–5.4 Figma → Task 7. §6 neutral secrets → Task 1. §7 no DSL change → confirmed: no task touches `test_flow.dart`. §8 reporting → Tasks 3, 8. §9 tests → every task. §10 acceptance → Task 10 Step 7. §11 limitations → Task 10 Step 6.

**Placeholder scan:** none. Every code step carries the code. The one judgement call left to the implementer is the name of the HTML-escaping helper in `html_reporter.dart` (Task 8 Step 3), which is named as a thing to look up rather than invented.

**Type consistency:** `ValidationDimension` and `.wire` used identically in Tasks 2, 3, 7, 8, 9. `ValidationResult.inDimension` defined in Task 2 Step 4, used in Task 2 Steps 6/8. `ApiSource.requiredEndpoint(String)` defined in Task 4 Step 3, used in Task 6 Step 3. `jsonResponse(...)` defined in Task 5 Step 3, used in Tasks 5, 6, 9. `FetchSucceeded`/`FetchFailed` consistent across Tasks 5, 6. `ApiAcquirer.acquire` named parameters identical in Task 6 Steps 1, 3, 7. `resolveFigmaSources` returns a record `(specs, failures)` in Task 7 Steps 1, 3, 6 alike. `SecretResolver.isPresent`/`resolve` as defined in Task 1 throughout.
