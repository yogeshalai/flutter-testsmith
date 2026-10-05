# E-05 Authentication Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `testsmith auth setup` — a deterministic, secure capability that establishes an authenticated application state by driving the application's real login UI with credentials taken from a secret reference, eliminating E-04's last manual prerequisite without any authentication bypass.

**Architecture:** A separate CLI command with its own declarative file, because authentication setup runs a *different build* (the UAT entry point, against the real backend) from the suite under test (the mytest entry point, against loopback) — the structural reason E-04 rejected a suite `setup:` phase. A `SecretRef`/`Secret` type split keeps the reference (which travels into YAML, logs and reports) apart from the value (whose `toString()` is `[REDACTED]`). Verification reads only what the application chose to show: the route its own router picked on a cold start, a rendered element, and its own login exchange.

**Tech Stack:** Dart 3.12 monorepo (`dart test`, `dart analyze --fatal-infos`), `package:args` CommandRunner, `package:yaml`, adb + `flutter run --machine` over the VM Service.

**Spec:** [docs/superpowers/specs/2026-09-14-e05-authentication-setup-design.md](../specs/2026-09-14-e05-authentication-setup-design.md)

## Global Constraints

- **DO NOT COMMIT.** The user's gate rule overrides this skill's default "commit at the end of each task". Every task ends with verification, not a commit. One commit happens only after explicit gate approval, covering everything. **Never push.**
- **Do not modify E-04 behaviour** unless a proven E-05 dependency requires it. Where an E-04 file is touched, the change must be additive and existing tests must pass unchanged.
- `dart analyze --fatal-infos` from the repo root must be clean after every task.
- `flutter_testsmith_engine` **must not** depend on `flutter_testsmith` (the runner must not pull Flutter in). `scripts/package_boundaries.dart` enforces this. The redaction marker literal is therefore duplicated, deliberately.
- Auth setup writes **no screenshot and no UI tree** into any artefact, ever.
- Every auth setup failure exits **2**. Never 1 — auth setup makes no claim about any screen. Usage errors are **64**. Success is **0**.
- Secret **values** may never appear in: YAML, Dart source, committed configuration, `result.json`, `suite.json`, `auth.json`, HTML reports, stdout/stderr, screenshots, debug logs, exception strings, generated evidence, or git history.
- Test commands: `dart test` from within the package directory; `dart analyze --fatal-infos` and `dart run scripts/check_dependencies.dart` from the repo root.
- Repo root is `D:\Repositories\flutter-ai-test-platform`. The application repo is `D:\Repositories\external_app`.

---

## File Structure

### `flutter_testsmith_engine` — new files

| file | responsibility |
|---|---|
| `lib/src/auth/secret_ref.dart` | `SecretRef`, `Secret`, `SecretResolver`, `MissingSecretException`, `redactionMarker`. The whole secret vocabulary, in one file, because these four types only make sense together. |
| `lib/src/auth/auth_flow.dart` | `AuthFile.parse` — the `mytest/auth/*.yaml` format, and the step refusals that are a security property. |
| `lib/src/auth/auth_result.dart` | `AuthSetupResult`, `AuthSetupOutcome`, `AuthSetupFailure`, allow-listed `toJson`. |
| `lib/src/auth/auth_verification.dart` | `classifyAuthSetup` — one pure function from observations to a verdict. Testable without a handset; this is where §9.0's precedence lives. |

### `flutter_testsmith_engine` — modified

| file | change |
|---|---|
| `lib/src/dsl/steps.dart` | `SecretInputStep` (must live here — `Step` is `sealed`). |
| `lib/src/device/device_controller.dart` | `inputSecret` on the interface. |
| `lib/src/device/adb_device_controller.dart` | `_adb` gains `display` + `scrub`; `inputSecret`. |
| `lib/flutter_testsmith_engine.dart` | export the four new files. |

### `flutter_testsmith_cli` — new files

| file | responsibility |
|---|---|
| `lib/src/env_secret_resolver.dart` | `EnvSecretResolver` — `Platform.environment`, then `DotEnv`. |
| `lib/src/auth_preflight.dart` | composes a `PreflightReport` for an auth file from E-04's existing pure check functions. |
| `lib/src/auth_runner.dart` | the seven-stage lifecycle. |
| `lib/src/commands/auth_command.dart` | `AuthCommand` + `AuthSetupSubcommand`. |

### `flutter_testsmith_cli` — modified

| file | change |
|---|---|
| `lib/src/flow_executor.dart` | rejecting `case SecretInputStep()`. |
| `lib/src/suite_runner.dart` | extract `grantPermissions` out of `grantDeclaredPermissions` so auth setup reuses it. Behaviour-preserving. |
| `bin/testsmith.dart` | register `AuthCommand`. |

### `external_app`

| file | change |
|---|---|
| `lib/features/auth/presentation/screens/secure_login_screen.dart` | three `TestId` wrappers. No behaviour change. |
| `mytest/auth/uat.yaml` | new. |
| `mytest/suites/regression.yaml` | the `authenticated` precondition's `remedy:` text. |

---

## Task 1: The secret vocabulary

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart`
- Test: `packages/flutter_testsmith_engine/test/secret_ref_test.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `const String redactionMarker`; `final class SecretRef` with `SecretRef({required String scheme, required String name})`, `factory SecretRef.parse(String raw, {required String source})`, `String toString()`, value equality; `final class Secret` with `const Secret(String value)`, `String expose()`, `bool get isEmpty`, `String toString()`; `abstract interface class SecretResolver` with `bool isPresent(SecretRef ref)` and `Secret resolve(SecretRef ref)`; `class MissingSecretException` with `final SecretRef ref`; `class SecretRefFormatException(String source, String message)`.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/secret_ref_test.dart`:

```dart
// The type split the whole milestone rests on: a reference is allowed to
// travel, a value is not. These tests are about the *rendering* of each,
// because rendering is how a credential actually escapes in practice -
// through a message somebody interpolated in a hurry.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Records every reference it was asked about, and whether it was ever
/// asked for a value.
class RecordingResolver implements SecretResolver {
  RecordingResolver(this._values);

  final Map<String, String> _values;
  final List<SecretRef> presenceChecks = [];
  final List<SecretRef> resolutions = [];

  @override
  bool isPresent(SecretRef ref) {
    presenceChecks.add(ref);
    return (_values[ref.name] ?? '').isNotEmpty;
  }

  @override
  Secret resolve(SecretRef ref) {
    resolutions.add(ref);
    final value = _values[ref.name];
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}

void main() {
  group('SecretRef.parse', () {
    test('reads scheme and name', () {
      final ref = SecretRef.parse('env:MYTEST_AUTH_PIN', source: 'auth.yaml');
      expect(ref.scheme, 'env');
      expect(ref.name, 'MYTEST_AUTH_PIN');
      expect(ref.toString(), 'env:MYTEST_AUTH_PIN');
    });

    test('a bare value is refused, because it would be a literal credential',
        () {
      expect(
        () => SecretRef.parse('1234', source: 'auth.yaml'),
        throwsA(isA<SecretRefFormatException>()),
      );
    });

    test('an unknown scheme is refused by name', () {
      expect(
        () => SecretRef.parse('vault:PIN', source: 'auth.yaml'),
        throwsA(
          isA<SecretRefFormatException>().having(
            (e) => e.message,
            'message',
            contains('vault'),
          ),
        ),
      );
    });

    test('a scheme with no name is refused', () {
      expect(
        () => SecretRef.parse('env:', source: 'auth.yaml'),
        throwsA(isA<SecretRefFormatException>()),
      );
    });

    test('equal references compare equal', () {
      expect(
        SecretRef.parse('env:A', source: 's'),
        SecretRef.parse('env:A', source: 's'),
      );
    });
  });

  group('Secret', () {
    test('interpolating one yields the marker, not the value', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      expect('$secret', redactionMarker);
      expect(secret.toString(), isNot(contains('SEEDED_PIN_9f2a41c8')));
    });

    test('a message built from one carries no credential', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      final message = 'could not type $secret into the field';
      expect(message, isNot(contains('SEEDED_PIN_9f2a41c8')));
      expect(message, contains(redactionMarker));
    });

    test('expose is the only way to the value', () {
      const secret = Secret('SEEDED_PIN_9f2a41c8');
      expect(secret.expose(), 'SEEDED_PIN_9f2a41c8');
    });
  });

  group('MissingSecretException', () {
    test('names the reference and nothing else', () {
      final error =
          MissingSecretException(SecretRef.parse('env:PIN', source: 's'));
      expect('$error', contains('env:PIN'));
      expect('$error', contains('PIN'));
    });
  });

  group('presence is checked without reading', () {
    test('isPresent answers without ever resolving', () {
      final resolver = RecordingResolver({'PIN': '1234'});
      final ref = SecretRef.parse('env:PIN', source: 's');

      expect(resolver.isPresent(ref), isTrue);
      expect(resolver.presenceChecks, [ref]);
      expect(
        resolver.resolutions,
        isEmpty,
        reason: 'a presence check must not pull the value into the process',
      );
    });

    test('an empty value is not present', () {
      final resolver = RecordingResolver({'PIN': ''});
      expect(resolver.isPresent(SecretRef.parse('env:PIN', source: 's')),
          isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_engine && dart test test/secret_ref_test.dart`
Expected: FAIL — `SecretRef`, `Secret`, `SecretResolver`, `redactionMarker` are undefined.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart`:

```dart
import 'package:meta/meta.dart';

/// What a credential is replaced by wherever one might otherwise print.
///
/// The same literal as the SDK's `RedactionPolicy.marker`, and
/// deliberately not imported from it: `flutter_testsmith_engine` must not depend on
/// `flutter_testsmith`, because the runner must not pull Flutter in, and
/// `scripts/package_boundaries.dart` holds that line. One literal in two
/// packages is the lesser of the two problems.
const String redactionMarker = '[REDACTED]';

/// A secret reference that is not one.
@immutable
class SecretRefFormatException implements Exception {
  const SecretRefFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'SecretRefFormatException in $source: $message';
}

/// *Where* a credential lives, never *what* it is.
///
/// This is the half that is allowed to travel: into YAML, into a step
/// description, into a report, onto the console. Keeping the halves in
/// two types is what turns "did we just print the secret?" from a review
/// question into a compiler question.
@immutable
final class SecretRef {
  const SecretRef({required this.scheme, required this.name});

  /// The only scheme E-05 implements. The seam for a second one is
  /// [SecretResolver], not this class - a file or keychain provider is a
  /// new implementation rather than a new design.
  static const String envScheme = 'env';

  final String scheme;
  final String name;

  factory SecretRef.parse(String raw, {required String source}) {
    Never bad(String message) =>
        throw SecretRefFormatException(source, message);

    final separator = raw.indexOf(':');
    if (separator <= 0) {
      bad(
        '"$raw" is not a secret reference. Expected "<scheme>:<name>", for '
        'example "env:MYTEST_AUTH_PIN". A literal credential is never '
        'accepted here.',
      );
    }

    final scheme = raw.substring(0, separator).trim();
    final name = raw.substring(separator + 1).trim();

    if (scheme != envScheme) {
      bad('unknown secret scheme "$scheme". Known: $envScheme.');
    }
    if (name.isEmpty) {
      bad('"$raw" names no variable after "$scheme:".');
    }
    return SecretRef(scheme: scheme, name: name);
  }

  @override
  String toString() => '$scheme:$name';

  @override
  bool operator ==(Object other) =>
      other is SecretRef && other.scheme == scheme && other.name == name;

  @override
  int get hashCode => Object.hash(scheme, name);
}

/// A resolved credential.
///
/// [toString] returns [redactionMarker], so interpolation - the way a
/// secret actually escapes in practice, through an error message
/// somebody added in a hurry - yields the marker rather than the
/// credential. [expose] is the only way out, and every call site of it is
/// a place worth reviewing.
final class Secret {
  const Secret(this._value);

  final String _value;

  String expose() => _value;

  bool get isEmpty => _value.isEmpty;

  @override
  String toString() => redactionMarker;
}

/// A reference that named nothing.
///
/// Carries the reference and nothing else. An exception that helpfully
/// printed the surrounding environment would be the leak this file
/// exists to prevent.
@immutable
class MissingSecretException implements Exception {
  const MissingSecretException(this.ref);

  final SecretRef ref;

  @override
  String toString() =>
      'MissingSecretException: $ref resolved to nothing. Set the ${ref.name} '
      'environment variable, or put it in a .env file that is not committed.';
}

/// Turns a reference into a value.
///
/// Two methods rather than one, and the split is the point. [isPresent]
/// answers "is it there?" and returns a bool, so a run can refuse before
/// it builds anything without the value ever entering the process.
/// [resolve] is called once, immediately before the interaction that
/// needs it, and nothing holds the result afterwards.
abstract interface class SecretResolver {
  bool isPresent(SecretRef ref);

  Secret resolve(SecretRef ref);
}
```

- [ ] **Step 4: Export it**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`, add alongside the other exports:

```dart
export 'src/auth/secret_ref.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_engine && dart test test/secret_ref_test.dart`
Expected: PASS, 11 tests.

- [ ] **Step 6: Verify nothing else broke**

Run from the repo root:
```
dart analyze --fatal-infos
dart run scripts/check_dependencies.dart
```
Expected: no issues. Record the output; **do not commit.**

---

## Task 2: `EnvSecretResolver`

**Files:**
- Create: `packages/flutter_testsmith_cli/lib/src/env_secret_resolver.dart`
- Test: `packages/flutter_testsmith_cli/test/env_secret_resolver_test.dart`

**Interfaces:**
- Consumes: `SecretRef`, `Secret`, `SecretResolver`, `MissingSecretException` from Task 1; the existing `DotEnv` from `packages/flutter_testsmith_cli/lib/src/dotenv.dart`.
- Produces: `class EnvSecretResolver implements SecretResolver` with constructor `EnvSecretResolver({DotEnv dotenv = const DotEnv.empty(), Map<String, String>? environment})`.

The `environment` parameter exists purely so the test does not have to mutate the real process environment, which Dart cannot do anyway.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_cli/test/env_secret_resolver_test.dart`:

```dart
// `DotEnv` already establishes the precedence rule - the real
// environment always wins, so CI is never overridden by a developer's
// local file that happened to reach a branch. The resolver inherits it
// rather than inventing a second one.

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/dotenv.dart';
import 'package:flutter_testsmith_cli/src/env_secret_resolver.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

SecretRef _ref(String raw) => SecretRef.parse(raw, source: 'test');

void main() {
  test('resolves from the process environment', () {
    final resolver = EnvSecretResolver(
      environment: {'MYTEST_AUTH_PIN': 'SEEDED_PIN_9f2a41c8'},
    );
    expect(
      resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(),
      'SEEDED_PIN_9f2a41c8',
    );
  });

  test('falls back to the .env file', () {
    final resolver = EnvSecretResolver(
      environment: const {},
      dotenv: DotEnv(DotEnv.parse('MYTEST_AUTH_PIN=FROM_FILE')),
    );
    expect(resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(), 'FROM_FILE');
  });

  test('the real environment wins over the file', () {
    final resolver = EnvSecretResolver(
      environment: {'MYTEST_AUTH_PIN': 'FROM_ENV'},
      dotenv: DotEnv(DotEnv.parse('MYTEST_AUTH_PIN=FROM_FILE')),
    );
    expect(resolver.resolve(_ref('env:MYTEST_AUTH_PIN')).expose(), 'FROM_ENV');
  });

  test('isPresent is true when set and false when absent or empty', () {
    final resolver = EnvSecretResolver(
      environment: {'SET': 'x', 'EMPTY': ''},
    );
    expect(resolver.isPresent(_ref('env:SET')), isTrue);
    expect(resolver.isPresent(_ref('env:EMPTY')), isFalse);
    expect(resolver.isPresent(_ref('env:ABSENT')), isFalse);
  });

  test('resolving an absent reference throws, naming only the reference', () {
    final resolver = EnvSecretResolver(environment: const {});
    expect(
      () => resolver.resolve(_ref('env:MYTEST_AUTH_PIN')),
      throwsA(
        isA<MissingSecretException>().having(
          (e) => '$e',
          'message',
          allOf(contains('env:MYTEST_AUTH_PIN'), isNot(contains('='))),
        ),
      ),
    );
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_cli && dart test test/env_secret_resolver_test.dart`
Expected: FAIL — `env_secret_resolver.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_cli/lib/src/env_secret_resolver.dart`:

```dart
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import 'dotenv.dart';

/// Resolves `env:NAME` references from the process environment, then
/// from a `.env` file.
///
/// That precedence is [DotEnv]'s own and is inherited rather than
/// restated: the real environment always wins, so CI - which sets
/// variables properly - is never overridden by a developer's local copy
/// that happened to get committed to a branch.
///
/// [environment] is injectable only so tests need not mutate the real
/// process environment, which Dart cannot do.
class EnvSecretResolver implements SecretResolver {
  EnvSecretResolver({
    DotEnv dotenv = const DotEnv.empty(),
    Map<String, String>? environment,
  })  : _dotenv = dotenv,
        _environment = environment ?? Platform.environment;

  final DotEnv _dotenv;
  final Map<String, String> _environment;

  /// The value, or null. Private, so nothing outside this class can get
  /// a credential as a bare String.
  String? _lookUp(SecretRef ref) =>
      _environment[ref.name] ?? _dotenv[ref.name];

  @override
  bool isPresent(SecretRef ref) => (_lookUp(ref) ?? '').isNotEmpty;

  @override
  Secret resolve(SecretRef ref) {
    final value = _lookUp(ref);
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_cli && dart test test/env_secret_resolver_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 5: Verify**

Run from the repo root: `dart analyze --fatal-infos`
Expected: no issues. **Do not commit.**

---

## Task 3: Close the `adb` credential leak, and add `SecretInputStep`

This is the fix the brief's §2 requires before E-05 can be called complete. `DeviceCommandException.toString()` renders the whole command, and `inputText` passes the typed value as an argument — so a failed `adb shell input text <PIN>` puts the PIN into `StepOutcome.detail`, `result.json`, `report.html` and stdout.

**Files:**
- Modify: `packages/flutter_testsmith_engine/lib/src/device/device_controller.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/device/adb_device_controller.dart`
- Modify: `packages/flutter_testsmith_engine/lib/src/dsl/steps.dart`
- Modify: `packages/flutter_testsmith_cli/lib/src/flow_executor.dart`
- Test: `packages/flutter_testsmith_engine/test/device_secret_input_test.dart`

**Interfaces:**
- Consumes: `Secret`, `SecretRef`, `redactionMarker` from Task 1.
- Produces: `Future<void> inputSecret(Secret secret)` on `DeviceController`; `final class SecretInputStep extends Step` with `SecretInputStep({required String elementId, required SecretRef ref})` and `String describe()`.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/device_secret_input_test.dart`:

```dart
// A credential must not reach an exception message.
//
// The leak this closes was real and specific: `DeviceCommandException`
// renders the whole command, `_adb` builds that string from the full
// argument vector, and `inputText` passes the typed value as an
// argument. A failed `adb shell input text <PIN>` therefore put the PIN
// into StepOutcome.detail, and from there into result.json, report.html
// and stdout.
//
// Asserted by searching the message for the literal, which is the
// discipline the existing leakage tests already use: checking that the
// right field was redacted proves only that the redactor did what it was
// told.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String seededPin = 'SEEDED_PIN_9f2a41c8';

/// Runs nothing, records what it was asked to run, and fails on demand.
class FakeRunner implements ProcessRunner {
  FakeRunner({this.exitCode = 0, this.stderr = ''});

  final int exitCode;
  final String stderr;
  final List<List<String>> calls = [];

  @override
  Future<ProcessResultData> run(String executable, List<String> arguments) async {
    calls.add(arguments);
    return ProcessResultData(
      exitCode: exitCode,
      stdout: '',
      stderr: stderr,
    );
  }
}

void main() {
  test('the real value is what reaches the device', () async {
    final runner = FakeRunner();
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    await device.inputSecret(const Secret(seededPin));

    expect(runner.calls.single, ['-s', 'S1', 'shell', 'input', 'text', seededPin]);
  });

  test('and never reaches the exception when the command fails', () async {
    final runner = FakeRunner(exitCode: 1);
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(seededPin));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect(error, isA<DeviceCommandException>());
    expect('$error', isNot(contains(seededPin)));
    expect('$error', contains(redactionMarker));
  });

  test('nor through stderr, if the device echoes it back', () async {
    final runner = FakeRunner(
      exitCode: 1,
      stderr: 'Error: bad argument "$seededPin"',
    );
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(seededPin));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect('$error', isNot(contains(seededPin)));
  });

  test('a space is escaped for `input text`, and the escaped form is '
      'scrubbed too', () async {
    const spaced = 'SEEDED VALUE';
    final runner = FakeRunner(exitCode: 1, stderr: 'saw SEEDED%sVALUE');
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    late final Object error;
    try {
      await device.inputSecret(const Secret(spaced));
      fail('expected a DeviceCommandException');
    } catch (thrown) {
      error = thrown;
    }

    expect('$error', isNot(contains('SEEDED%sVALUE')));
    expect('$error', isNot(contains(spaced)));
  });

  test('inputText is untouched, so no E-04 behaviour changes', () async {
    final runner = FakeRunner();
    final device = AdbDeviceController(serial: 'S1', processRunner: runner);

    await device.inputText('hello world');

    expect(
      runner.calls.single,
      ['-s', 'S1', 'shell', 'input', 'text', 'hello%sworld'],
    );
  });

  group('SecretInputStep', () {
    test('describes the reference and never a value', () {
      final step = SecretInputStep(
        elementId: 'secure_login.pin_field',
        ref: SecretRef.parse('env:MYTEST_AUTH_PIN', source: 'test'),
      );

      expect(
        step.describe(),
        'type <env:MYTEST_AUTH_PIN> into "secure_login.pin_field"',
      );
      expect(step.describe(), isNot(contains(seededPin)));
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_engine && dart test test/device_secret_input_test.dart`
Expected: FAIL — `inputSecret` and `SecretInputStep` are undefined.

- [ ] **Step 3: Add `inputSecret` to the interface**

In `packages/flutter_testsmith_engine/lib/src/device/device_controller.dart`, add this import at the top:

```dart
import '../auth/secret_ref.dart';
```

and add this member to `abstract interface class DeviceController`, immediately after `Future<void> inputText(String text);`:

```dart
  /// Types a credential into the focused field.
  ///
  /// Separate from [inputText] rather than a flag on it, because the
  /// value must not reach [DeviceCommandException], whose message
  /// renders the command it ran. A flag would leave the leaking path one
  /// forgotten `false` away.
  Future<void> inputSecret(Secret secret);
```

- [ ] **Step 4: Implement it, and give `_adb` a redacted rendering**

In `packages/flutter_testsmith_engine/lib/src/device/adb_device_controller.dart`, add the import:

```dart
import '../auth/secret_ref.dart';
```

Replace the existing `_adb` method with:

```dart
  /// Runs an adb command, and controls what a failure is allowed to say.
  ///
  /// [display] replaces the arguments in the exception's command string,
  /// and [scrub] removes literals from the device's own stderr. Both
  /// exist for exactly one caller - [inputSecret] - because the
  /// exception message is the one place a typed credential would
  /// otherwise surface.
  Future<ProcessResultData> _adb(
    List<String> arguments, {
    List<String>? display,
    Iterable<String> scrub = const [],
  }) async {
    final full = ['-s', serial, ...arguments];
    final result = await _runner.run(adbExecutable, full);
    if (!result.succeeded) {
      final shown = ['-s', serial, ...(display ?? arguments)];
      var stderr = result.stderr;
      for (final literal in scrub) {
        if (literal.isEmpty) continue;
        stderr = stderr.replaceAll(literal, redactionMarker);
      }
      throw DeviceCommandException(
        command: '$adbExecutable ${shown.join(' ')}',
        exitCode: result.exitCode,
        stderr: stderr,
      );
    }
    return result;
  }
```

Then add, immediately after the existing `inputText`:

```dart
  @override
  Future<void> inputSecret(Secret secret) async {
    final value = secret.expose();
    // Same escaping as `inputText`: `input text` treats spaces as
    // argument separators.
    final escaped = value.replaceAll(' ', '%s');
    await _adb(
      ['shell', 'input', 'text', escaped],
      display: const ['shell', 'input', 'text', redactionMarker],
      // Both forms: the escaped one is what was passed, and the raw one
      // is what a shell might echo back.
      scrub: {escaped, value},
    );
  }
```

- [ ] **Step 5: Add `SecretInputStep`**

In `packages/flutter_testsmith_engine/lib/src/dsl/steps.dart`, add the import:

```dart
import '../auth/secret_ref.dart';
```

and add this class immediately after `InputStep`:

```dart
/// Types a credential into a field, naming only where it came from.
///
/// Not a flag on [InputStep]: that step's `describe()` renders the
/// value, which is exactly right for a test step and exactly wrong for a
/// credential. A separate type makes the safe rendering the only
/// rendering.
///
/// Declared here because [Step] is `sealed` and Dart permits subclasses
/// only in the declaring library - which is a benefit: the executor's
/// switch is checked for exhaustiveness, so this forces an explicit
/// decision at the one place that runs product flows.
///
/// Only an auth flow may contain one. `TestFlow.parse` cannot produce
/// one and `FlowExecutor` refuses one.
final class SecretInputStep extends Step {
  const SecretInputStep({required this.elementId, required this.ref});

  final String elementId;

  /// The reference, never the value. This is what reaches the report.
  final SecretRef ref;

  @override
  String describe() => 'type <$ref> into "$elementId"';
}
```

- [ ] **Step 6: Make `FlowExecutor` refuse it**

In `packages/flutter_testsmith_cli/lib/src/flow_executor.dart`, inside `_execute`'s switch, add this case immediately after `case InputStep(...)`:

```dart
      // A second lock on a door that is already shut: `TestFlow.parse`
      // cannot produce this step. Reaching here would mean a credential
      // was about to be typed by something whose report renders values.
      case SecretInputStep():
        throw StateError(
          'a secret input step is only valid in an auth flow; `testsmith run` '
          'and `testsmith suite run` refuse it',
        );
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_engine && dart test test/device_secret_input_test.dart`
Expected: PASS, 6 tests.

- [ ] **Step 8: Verify the whole engine and CLI still pass**

Run:
```
cd packages/flutter_testsmith_engine && dart test
cd ../flutter_testsmith_cli && dart test
cd ../.. && dart analyze --fatal-infos
```
Expected: all green. If `device_test.dart` has a fake `DeviceController` implementing the interface, it will need an `inputSecret` stub — add:

```dart
  @override
  Future<void> inputSecret(Secret secret) async => inputText(secret.expose());
```

to any test fake that implements `DeviceController`. **Do not commit.**

---

## Task 4: The auth file format

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/auth/auth_flow.dart`
- Test: `packages/flutter_testsmith_engine/test/auth_flow_test.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`

**Interfaces:**
- Consumes: `SecretRef`, `SecretRefFormatException` (Task 1); `SecretInputStep` (Task 3); existing `Step` subclasses, `ExpectApiStep`, `ApiEndpoint`.
- Produces:
  - `class AuthFormatException(String source, String message)`
  - `final class AuthUiState` — `AuthUiState({required String route, required String element})`
  - `final class AuthVerify` — `AuthVerify({required String route, required String element, required Duration timeout, ExpectApiStep? request, List<String> notOn, AuthUiState? invalidCredentialOn})`
  - `final class AuthFile` — fields `String name`, `SuiteApp app`, `String appId`, `String deviceProfile`, `List<String> devicePermissions`, `Map<String, SecretRef> secrets`, `List<String> signedOutOn`, `List<Step> onboarding`, `List<Step> login`, `AuthVerify verify`; `factory AuthFile.parse(String yamlText, {required String source})`; `List<SecretRef> get declaredSecrets`.

`SuiteApp` is reused from `dsl/suite_file.dart` rather than duplicated — it already means exactly "how the application under test is built and launched".

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/auth_flow_test.dart`:

```dart
// The auth file, and the four steps it refuses.
//
// The refusals are the reason this parser exists rather than reusing
// TestFlow: a security property that depends on nobody writing the wrong
// line is not a security property. `screenshot` would photograph a
// screen showing an unobscured mobile number; `validateScreen`
// photographs and writes trees into a report; `input` is a plaintext
// credential; and an assertion belongs in `verify:`, where its shape is
// constrained.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _valid = '''
auth: test
app:
  path: ../..
  target: lib/main_example.dart
  flavor: example
appId: com.example.testapp.alpha
device:
  profile: samsung-m127g
  permissions:
    - android.permission.ACCESS_FINE_LOCATION
secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN
signedOutOn: [/onboarding, /login]
onboarding:
  - expectScreen: {id: /onboarding, timeoutMs: 40000}
  - tap: {id: onboarding.get_started}
login:
  - expectScreen: {id: /login, timeoutMs: 40000}
  - waitForSettle: {timeoutMs: 30000}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}
verify:
  route: /home
  timeoutMs: 60000
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location]
  invalidCredentialOn:
    route: /secure-login
    element: secure_login.pin_error
''';

AuthFile _parse(String yaml) => AuthFile.parse(yaml, source: 'auth.yaml');

String _without(String block) {
  // Removes one top-level block from the valid document, for the
  // "required key" tests.
  final lines = _valid.split('\n');
  final out = <String>[];
  var skipping = false;
  for (final line in lines) {
    if (line.startsWith('$block:')) {
      skipping = true;
      continue;
    }
    if (skipping && line.isNotEmpty && !line.startsWith(' ')) skipping = false;
    if (!skipping) out.add(line);
  }
  return out.join('\n');
}

void main() {
  group('a valid file', () {
    test('reads its name, build and application id', () {
      final file = _parse(_valid);
      expect(file.name, 'test');
      expect(file.app.target, 'lib/main_example.dart');
      expect(file.app.flavor, 'example');
      expect(file.app.path, '../..');
      expect(file.appId, 'com.example.testapp.alpha');
    });

    test('reads its device profile and permissions', () {
      final file = _parse(_valid);
      expect(file.deviceProfile, 'samsung-m127g');
      expect(
        file.devicePermissions,
        ['android.permission.ACCESS_FINE_LOCATION'],
      );
    });

    test('reads secrets as references, never as values', () {
      final file = _parse(_valid);
      expect(file.secrets['pin'].toString(), 'env:MYTEST_AUTH_PIN');
      expect(file.secrets['mobile'].toString(), 'env:MYTEST_AUTH_MOBILE');
      expect(file.declaredSecrets, hasLength(2));
    });

    test('reads both step blocks', () {
      final file = _parse(_valid);
      expect(file.onboarding, hasLength(2));
      expect(file.login, hasLength(6));
      expect(file.login[2], isA<SecretInputStep>());
    });

    test('a secret step carries the reference the secrets block named', () {
      final step = _parse(_valid).login[2] as SecretInputStep;
      expect(step.elementId, 'login.mobile_field');
      expect(step.ref.name, 'MYTEST_AUTH_MOBILE');
      expect(step.describe(), contains('env:MYTEST_AUTH_MOBILE'));
    });

    test('reads the verify block', () {
      final verify = _parse(_valid).verify;
      expect(verify.route, '/home');
      expect(verify.element, 'home.body');
      expect(verify.timeout, const Duration(milliseconds: 60000));
      expect(verify.notOn, ['/set-location']);
      expect(verify.request!.status, 200);
      expect(verify.request!.expectations, isEmpty);
      expect(verify.invalidCredentialOn!.route, '/secure-login');
      expect(verify.invalidCredentialOn!.element, 'secure_login.pin_error');
    });

    test('onboarding may be omitted', () {
      final file = _parse(_without('onboarding'));
      expect(file.onboarding, isEmpty);
    });
  });

  group('refusals that are security properties', () {
    Matcher refusedBecause(String reason) => throwsA(
          isA<AuthFormatException>()
              .having((e) => e.message, 'message', contains(reason)),
        );

    test('screenshot is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - screenshot: {name: login}',
        )),
        refusedBecause('screenshot'),
      );
    });

    test('validateScreen is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - validateScreen: {figma: true}',
        )),
        refusedBecause('validateScreen'),
      );
    });

    test('plaintext input is refused, and says why', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - inputSecret: {id: login.mobile_field, secret: mobile}',
          '  - input: {id: login.mobile_field, value: "9876543210"}',
        )),
        refusedBecause('secret reference'),
      );
    });

    test('expectApi in a step block is refused', () {
      expect(
        () => _parse(_valid.replaceFirst(
          '  - tap: {id: login.continue_button}',
          '  - expectApi: {endpoint: GET /x, status: 200}',
        )),
        refusedBecause('verify'),
      );
    });
  });

  group('malformed files', () {
    test('a secret named by a step but not declared is refused', () {
      expect(
        () => _parse(_valid.replaceFirst('secret: pin}', 'secret: otp}')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a literal credential in the secrets block is refused', () {
      expect(
        () => _parse(_valid.replaceFirst('env:MYTEST_AUTH_PIN', '1234')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('an unknown top-level key is refused', () {
      expect(
        () => _parse('$_valid\nbypass: true\n'),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a missing verify block is refused', () {
      expect(
        () => _parse(_without('verify')),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('an empty signedOutOn is refused, because it could never match', () {
      expect(
        () => _parse(_valid.replaceFirst(
          'signedOutOn: [/onboarding, /login]',
          'signedOutOn: []',
        )),
        throwsA(isA<AuthFormatException>()),
      );
    });

    test('a missing appId is refused', () {
      expect(
        () => _parse(_without('appId')),
        throwsA(isA<AuthFormatException>()),
      );
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_flow_test.dart`
Expected: FAIL — `AuthFile` is undefined.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_engine/lib/src/auth/auth_flow.dart`:

```dart
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../dsl/steps.dart';
import '../dsl/suite_file.dart';
import '../validation/api_expectation.dart';
import 'secret_ref.dart';

/// A malformed auth file.
@immutable
class AuthFormatException implements Exception {
  const AuthFormatException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => 'AuthFormatException in $source: $message';
}

/// A route the application shows, and something on it.
///
/// Used to declare what "that credential was wrong" looks like in *this*
/// application, because inferring it from an HTTP status would be a
/// guess about a convention neither this repository nor the application
/// controls.
@immutable
final class AuthUiState {
  const AuthUiState({required this.route, required this.element});

  final String route;
  final String element;
}

/// What must be true for setup to have worked.
@immutable
final class AuthVerify {
  const AuthVerify({
    required this.route,
    required this.element,
    required this.timeout,
    this.request,
    this.notOn = const [],
    this.invalidCredentialOn,
  });

  /// The route the application's own router must have chosen.
  final String route;

  /// An element that must be present on it - so a route event without a
  /// rendered screen is not mistaken for a working dashboard.
  final String element;

  /// How long to wait for [route], from the last login step, or from
  /// launch on the already-authenticated path. It covers the real
  /// authentication request and the location gate behind it.
  final Duration timeout;

  /// The application's own authentication exchange. Asserted only when a
  /// login was actually performed.
  ///
  /// Declared with a status and no field expectations, so nothing of the
  /// body can ride into a report.
  final ExpectApiStep? request;

  /// Routes that mean setup did not work, named so the report can say
  /// which one.
  final List<String> notOn;

  /// How this application says the credential was wrong.
  final AuthUiState? invalidCredentialOn;
}

/// How to reach an authenticated state through the real login UI.
///
/// A file of its own, rather than a block in a suite, because setup runs
/// a *different build* from the tests: the UAT entry point against the
/// real backend, where the suite runs the mytest entry point against
/// loopback. A suite's single `app:` block cannot express two, and making
/// it able to would make a suite file two suites.
@immutable
final class AuthFile {
  const AuthFile({
    required this.name,
    required this.app,
    required this.appId,
    required this.deviceProfile,
    required this.devicePermissions,
    required this.secrets,
    required this.signedOutOn,
    required this.onboarding,
    required this.login,
    required this.verify,
  });

  final String name;
  final SuiteApp app;

  /// Checked against the handshake, so the runner proves which
  /// application it is driving rather than assuming the one it asked for
  /// is the one that answered.
  final String appId;

  final String deviceProfile;
  final List<String> devicePermissions;

  /// Named references, never values.
  final Map<String, SecretRef> secrets;

  /// Routes this application's own router shows when it holds no
  /// session. Declared by a person, exactly as E-04's `unmetOn` is, and
  /// for the same reason: only a person knows that *this* application
  /// shows these routes.
  final List<String> signedOutOn;

  /// Steps from an onboarding route to the login form. Empty when this
  /// application has no onboarding.
  final List<Step> onboarding;

  /// Steps from the login form to submitted credentials.
  final List<Step> login;

  final AuthVerify verify;

  List<SecretRef> get declaredSecrets => secrets.values.toList();

  static const Set<String> _topLevelKeys = {
    'auth',
    'app',
    'appId',
    'device',
    'secrets',
    'signedOutOn',
    'onboarding',
    'login',
    'verify',
  };

  /// Steps an auth flow may contain, and what each takes.
  ///
  /// Everything absent from this map is refused by name in [_step].
  static const Map<String, Set<String>> _stepArguments = {
    'launchApp': {},
    'waitForSettle': {'timeoutMs'},
    'tap': {'id'},
    'back': {},
    'expectScreen': {'id', 'timeoutMs'},
    'expectElement': {
      'id',
      'present',
      'enabled',
      'visible',
      'text',
      'textContains',
      'timeoutMs',
    },
    'inputSecret': {'id', 'secret'},
  };

  /// Steps refused on purpose, each with the reason printed.
  ///
  /// A parse-time refusal rather than a convention, because a security
  /// property that depends on nobody writing the wrong line is not a
  /// security property.
  static const Map<String, String> _refusedSteps = {
    'screenshot': 'an authentication screen shows an unobscured mobile '
        'number, so auth setup photographs nothing',
    'validateScreen': 'it photographs the screen and writes a UI tree into a '
        'report, and an authentication screen may carry a credential',
    'input': 'a plaintext value. Every credential must go through a secret '
        'reference: use "inputSecret" with a name from the "secrets" block',
    'expectApi': 'an assertion belongs in the "verify" block, where its shape '
        'is constrained to an endpoint and a status',
  };

  factory AuthFile.parse(String yamlText, {required String source}) {
    Never bad(String message) => throw AuthFormatException(source, message);

    final Object? loaded;
    try {
      loaded = loadYaml(yamlText);
    } on YamlException catch (error) {
      bad('invalid YAML: ${error.message}');
    }
    if (loaded is! Map) {
      bad('expected a mapping at the root with auth, app, device and verify');
    }

    Map<String, Object?> asMap(Object? node, String what) {
      if (node is! Map) bad('"$what" must be a mapping');
      return node
          .cast<Object?, Object?>()
          .map((key, value) => MapEntry(key.toString(), value));
    }

    void checkKeys(Map<String, Object?> map, Set<String> known, String what) {
      for (final key in map.keys) {
        if (known.contains(key)) continue;
        bad('unknown $what key "$key". Known: ${known.join(', ')}.');
      }
    }

    List<String> asStringList(Object? node, String what) {
      if (node == null) return const [];
      if (node is! List) bad('"$what" must be a list');
      return [for (final item in node) item.toString()];
    }

    final root = asMap(loaded, 'root');
    checkKeys(root, _topLevelKeys, 'top-level');

    final name = root['auth'];
    if (name is! String || name.isEmpty) {
      bad('an auth file needs an "auth" name');
    }

    final appId = root['appId'];
    if (appId is! String || appId.isEmpty) {
      bad(
        'an auth file needs an "appId" - the package the handshake must '
        'report, so the runner proves which application it is driving',
      );
    }

    // ── app ──────────────────────────────────────────────────────────
    final appNode = root['app'];
    if (appNode == null) {
      bad('an auth file needs an "app" block naming the build to launch');
    }
    final appMap = asMap(appNode, 'app');
    checkKeys(appMap, const {'path', 'target', 'flavor', 'dartDefines'}, 'app');
    final defines = appMap['dartDefines'];
    if (defines != null && defines is! List) {
      bad('"app.dartDefines" must be a list');
    }
    final app = SuiteApp(
      path: appMap['path']?.toString() ?? '.',
      target: appMap['target']?.toString(),
      flavor: appMap['flavor']?.toString(),
      dartDefines: asStringList(defines, 'app.dartDefines'),
    );

    // ── device ───────────────────────────────────────────────────────
    final device = asMap(root['device'] ?? const {}, 'device');
    checkKeys(device, const {'profile', 'permissions'}, 'device');
    final profile = device['profile'];
    if (profile is! String || profile.isEmpty) {
      bad(
        'an auth file needs "device: profile:" - the id of a device profile, '
        'not a device serial',
      );
    }
    final permissions = asStringList(device['permissions'], 'device.permissions');

    // ── secrets ──────────────────────────────────────────────────────
    final secrets = <String, SecretRef>{};
    final rawSecrets = root['secrets'];
    if (rawSecrets != null) {
      final map = asMap(rawSecrets, 'secrets');
      for (final entry in map.entries) {
        try {
          secrets[entry.key] =
              SecretRef.parse(entry.value.toString(), source: source);
        } on SecretRefFormatException catch (error) {
          bad('secret "${entry.key}": ${error.message}');
        }
      }
    }

    // ── signedOutOn ──────────────────────────────────────────────────
    final signedOutOn = asStringList(root['signedOutOn'], 'signedOutOn');
    if (signedOutOn.isEmpty) {
      bad(
        '"signedOutOn" must name at least one route. It is what tells the '
        'runner the application is holding no session; with none, an '
        'unauthenticated launch could never be recognised as one.',
      );
    }

    // ── steps ────────────────────────────────────────────────────────
    Step step(Object? node, String block) {
      final map = asMap(node, '$block step');
      if (map.length != 1) {
        bad('every $block step is one key, such as "tap:". Found: '
            '${map.keys.join(', ')}');
      }
      final stepName = map.keys.single;

      final refusal = _refusedSteps[stepName];
      if (refusal != null) {
        bad('"$stepName" is not allowed in an auth flow: $refusal');
      }

      final known = _stepArguments[stepName];
      if (known == null) {
        bad('unknown step "$stepName". Known: '
            '${_stepArguments.keys.join(', ')}.');
      }

      final args = map[stepName] == null
          ? <String, Object?>{}
          : asMap(map[stepName], '"$stepName" arguments');
      checkKeys(args, known, '"$stepName"');

      String requireString(String key) {
        final value = args[key];
        if (value is! String || value.isEmpty) {
          bad('"$stepName" needs a "$key"');
        }
        return value;
      }

      Duration timeout(int fallback) => Duration(
            milliseconds: (args['timeoutMs'] as num?)?.toInt() ?? fallback,
          );

      bool? optionalBool(String key) {
        if (!args.containsKey(key)) return null;
        final value = args[key];
        if (value is! bool) {
          bad('"$stepName" needs true or false for "$key", not "$value"');
        }
        return value;
      }

      return switch (stepName) {
        'launchApp' => const LaunchAppStep(),
        'back' => const BackStep(),
        'waitForSettle' => WaitForSettleStep(timeout: timeout(10000)),
        'tap' => TapStep(requireString('id')),
        'expectScreen' =>
          ExpectScreenStep(requireString('id'), timeout: timeout(5000)),
        'expectElement' => ExpectElementStep(
            elementId: requireString('id'),
            present: optionalBool('present'),
            enabled: optionalBool('enabled'),
            visible: optionalBool('visible'),
            text: args['text'] as String?,
            textContains: args['textContains'] as String?,
            timeout: timeout(5000),
          ),
        'inputSecret' => () {
            final key = requireString('secret');
            final ref = secrets[key];
            if (ref == null) {
              bad(
                '"inputSecret" names the secret "$key", which the "secrets" '
                'block does not declare. Known: '
                '${secrets.isEmpty ? '(none)' : secrets.keys.join(', ')}.',
              );
            }
            return SecretInputStep(elementId: requireString('id'), ref: ref);
          }(),
        _ => bad('unhandled step "$stepName"'),
      };
    }

    List<Step> block(String key) {
      final node = root[key];
      if (node == null) return const [];
      if (node is! List) bad('"$key" must be a list of steps');
      return [for (final entry in node) step(entry, key)];
    }

    final onboarding = block('onboarding');
    final login = block('login');
    if (login.isEmpty) {
      bad('an auth file needs a non-empty "login" block');
    }

    // ── verify ───────────────────────────────────────────────────────
    final verifyNode = root['verify'];
    if (verifyNode == null) {
      bad(
        'an auth file needs a "verify" block. Without one, setup could only '
        'report that it tapped a button, which is not evidence of a session.',
      );
    }
    final verifyMap = asMap(verifyNode, 'verify');
    checkKeys(
      verifyMap,
      const {
        'route',
        'element',
        'timeoutMs',
        'request',
        'notOn',
        'invalidCredentialOn',
      },
      'verify',
    );

    final route = verifyMap['route'];
    if (route is! String || route.isEmpty) {
      bad('"verify" needs a "route" - the authenticated route to reach');
    }
    final element = verifyMap['element'];
    if (element is! String || element.isEmpty) {
      bad(
        '"verify" needs an "element" present on that route, so a route event '
        'without a rendered screen is not mistaken for a working one',
      );
    }

    ExpectApiStep? request;
    final requestNode = verifyMap['request'];
    if (requestNode != null) {
      final map = asMap(requestNode, 'verify.request');
      checkKeys(map, const {'endpoint', 'status'}, 'verify.request');
      final endpoint = map['endpoint'];
      if (endpoint is! String || endpoint.isEmpty) {
        bad('"verify.request" needs an "endpoint", such as "POST /login"');
      }
      final status = map['status'];
      if (status is! int) {
        bad('"verify.request" needs a "status" the application received');
      }
      request = ExpectApiStep(
        endpoint: ApiEndpoint.parse(endpoint),
        status: status,
      );
    }

    AuthUiState? invalidCredentialOn;
    final invalidNode = verifyMap['invalidCredentialOn'];
    if (invalidNode != null) {
      final map = asMap(invalidNode, 'verify.invalidCredentialOn');
      checkKeys(map, const {'route', 'element'}, 'verify.invalidCredentialOn');
      final invalidRoute = map['route'];
      final invalidElement = map['element'];
      if (invalidRoute is! String || invalidRoute.isEmpty) {
        bad('"verify.invalidCredentialOn" needs a "route"');
      }
      if (invalidElement is! String || invalidElement.isEmpty) {
        bad('"verify.invalidCredentialOn" needs an "element"');
      }
      invalidCredentialOn =
          AuthUiState(route: invalidRoute, element: invalidElement);
    }

    return AuthFile(
      name: name,
      app: app,
      appId: appId,
      deviceProfile: profile,
      devicePermissions: permissions,
      secrets: secrets,
      signedOutOn: signedOutOn,
      onboarding: onboarding,
      login: login,
      verify: AuthVerify(
        route: route,
        element: element,
        timeout: Duration(
          milliseconds: (verifyMap['timeoutMs'] as num?)?.toInt() ?? 60000,
        ),
        request: request,
        notOn: asStringList(verifyMap['notOn'], 'verify.notOn'),
        invalidCredentialOn: invalidCredentialOn,
      ),
    );
  }
}
```

**Note for the implementer:** `ApiEndpoint.parse` may be named differently. Check `packages/flutter_testsmith_engine/lib/src/validation/api_expectation.dart` for how `test_flow.dart`'s `_readExpectApi` builds an `ApiEndpoint` from the string `"GET /api/x"`, and use exactly that call. Do not invent a second parser.

- [ ] **Step 4: Export it**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`:

```dart
export 'src/auth/auth_flow.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_flow_test.dart`
Expected: PASS, 19 tests.

- [ ] **Step 6: Verify**

Run: `cd packages/flutter_testsmith_engine && dart test` then from root `dart analyze --fatal-infos`
Expected: all green. **Do not commit.**

---

## Task 5: The result, and its allow-listed serialisation

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/auth/auth_result.dart`
- Test: `packages/flutter_testsmith_engine/test/auth_leakage_test.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`

**Interfaces:**
- Consumes: `SecretRef` (Task 1), `ApiExpectationOutcome` (existing).
- Produces:
  - `enum AuthSetupOutcome { succeeded, failed }` with `String wire`
  - `enum AuthSetupFailure` with `String wire` and `PrerequisiteClass klass`, values: `secretMissing`, `invalidCredential`, `loginUiNotFound`, `authRequestFailed`, `authPathNotSupported`, `authenticatedStateNotReached`, `environmentPrerequisite`
  - `final class AuthSetupResult` — `AuthSetupResult({required AuthSetupOutcome outcome, AuthSetupFailure? failure, String detail, String remedy, String? route, List<String> routeHistory, required bool loginPerformed, bool elementVerified, ApiExpectationOutcome? request, int durationMs, List<SecretRef> secretsUsed, String? appId, String? appVersion, String? buildMode, String? deviceModel})`; `Map<String, Object?> toJson()`; `int get exitCode`; `bool get succeeded`

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/auth_leakage_test.dart`:

```dart
// Brief item 9 - what auth setup leaves on disk.
//
// Every assertion searches the serialised text for the literal, because
// the failure being guarded against is a route nobody thought of, not a
// field somebody forgot to redact. Same discipline as
// report_leakage_test and secret_leakage_test.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Values seeded into a result the way a leak would put them there.
const Map<String, String> seeds = {
  'mobile number': '9876543210',
  'PIN': 'SEEDED_PIN_9f2a41c8',
  'access token': 'SEEDED_ACCESS_TOKEN_8a17fc',
  'session cookie': 'MOCK_SESSION_SECRET',
};

AuthSetupResult _succeeded() => AuthSetupResult(
      outcome: AuthSetupOutcome.succeeded,
      route: '/home',
      routeHistory: const ['/', '/home'],
      loginPerformed: false,
      elementVerified: true,
      durationMs: 41200,
      secretsUsed: [
        SecretRef.parse('env:MYTEST_AUTH_MOBILE', source: 't'),
        SecretRef.parse('env:MYTEST_AUTH_PIN', source: 't'),
      ],
      appId: 'com.example.testapp.alpha',
      appVersion: '1.0.6',
      buildMode: 'debug',
      deviceModel: 'SM-M127G',
    );

/// A failure whose every free-text field has been stuffed with a
/// credential - what the result would carry if a message somewhere had
/// interpolated a `String` instead of a `Secret`.
AuthSetupResult _polluted() => AuthSetupResult(
      outcome: AuthSetupOutcome.failed,
      failure: AuthSetupFailure.invalidCredential,
      detail: 'rejected',
      remedy: 'check the credential',
      route: '/secure-login',
      routeHistory: const ['/', '/onboarding', '/login', '/secure-login'],
      loginPerformed: true,
      elementVerified: false,
      durationMs: 38100,
      secretsUsed: [SecretRef.parse('env:MYTEST_AUTH_PIN', source: 't')],
      appId: 'com.example.testapp.alpha',
      deviceModel: 'SM-M127G',
    );

void main() {
  group('the serialised result', () {
    test('carries only the keys the allow-list names', () {
      // An allow-list, because a deny-list only ever catches the secrets
      // somebody remembered.
      expect(
        _succeeded().toJson().keys.toSet(),
        {
          'outcome',
          'route',
          'routeHistory',
          'loginPerformed',
          'elementVerified',
          'durationMs',
          'secretsUsed',
          'appId',
          'appVersion',
          'buildMode',
          'deviceModel',
        },
      );
    });

    test('a failure adds its classification, detail and remedy - and '
        'nothing else', () {
      expect(
        _polluted().toJson().keys.toSet().difference(
              _succeeded().toJson().keys.toSet(),
            ),
        {'classification', 'detail', 'remedy'},
      );
    });

    test('records references, never values', () {
      final json = _succeeded().toJson();
      expect(json['secretsUsed'], ['env:MYTEST_AUTH_MOBILE', 'env:MYTEST_AUTH_PIN']);
    });

    test('no seeded secret reaches it', () {
      for (final result in [_succeeded(), _polluted()]) {
        final text = jsonEncode(result.toJson());
        for (final entry in seeds.entries) {
          expect(text, isNot(contains(entry.value)), reason: entry.key);
        }
      }
    });

    test('and neither does the device serial', () {
      // The serial is an address, not an identity - as E-03 established
      // for baselines and E-04 for preflight. The model is recorded.
      final text = jsonEncode(_succeeded().toJson());
      expect(text, isNot(contains('RZ8T11QETWM')));
      expect(text, contains('SM-M127G'));
    });

    test('nothing names the storage route this platform refuses', () {
      final text = jsonEncode(_polluted().toJson()).toLowerCase();
      for (final forbidden in const [
        'is_logged_in',
        'sharedpreferences',
        'run-as',
        'token',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  group('exit codes', () {
    test('success is 0', () {
      expect(_succeeded().exitCode, 0);
      expect(_succeeded().succeeded, isTrue);
    });

    test('every failure is 2, never 1', () {
      // Auth setup makes no claim about any screen, so it is never in a
      // position to say the application is wrong.
      for (final failure in AuthSetupFailure.values) {
        final result = AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: failure,
          loginPerformed: false,
        );
        expect(result.exitCode, 2, reason: failure.wire);
      }
    });
  });

  group('classification', () {
    test('every failure carries a prerequisite class', () {
      for (final failure in AuthSetupFailure.values) {
        expect(failure.klass, isA<PrerequisiteClass>(), reason: failure.wire);
      }
    });

    test('wire names are stable and distinct', () {
      final wires = AuthSetupFailure.values.map((f) => f.wire).toList();
      expect(wires.toSet(), hasLength(wires.length));
      expect(wires, contains('SECRET_MISSING'));
      expect(wires, contains('AUTHENTICATED_STATE_NOT_REACHED'));
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_leakage_test.dart`
Expected: FAIL — `AuthSetupResult` is undefined.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_engine/lib/src/auth/auth_result.dart`:

```dart
import 'package:meta/meta.dart';

import '../environment/prerequisite.dart';
import '../validation/api_expectation.dart';
import 'secret_ref.dart';

/// Whether setup established an authenticated state.
enum AuthSetupOutcome {
  succeeded('succeeded'),
  failed('failed');

  const AuthSetupOutcome(this.wire);

  final String wire;
}

/// Why setup did not establish one.
///
/// Distinct values rather than a message, because the whole point of
/// E-04's classification was that "the run failed" is not actionable.
/// Each carries the class that owns it, so the report says which person
/// to send it to.
enum AuthSetupFailure {
  /// A declared reference resolved to nothing. Nothing was launched and
  /// nothing was typed.
  secretMissing(
    'SECRET_MISSING',
    PrerequisiteClass.runnerControlled,
    'Set the environment variable the auth file names, or put it in a '
        '.env file that is not committed.',
  ),

  /// The application itself said the credential was wrong - it stayed on
  /// its own error state rather than moving on.
  invalidCredential(
    'INVALID_CREDENTIAL',
    PrerequisiteClass.humanAction,
    'Check the credential behind the secret reference. The application '
        'rejected it through its own login flow.',
  ),

  /// A declared element was not in the tree.
  loginUiNotFound(
    'LOGIN_UI_NOT_FOUND',
    PrerequisiteClass.applicationControlled,
    'The login UI does not carry the element the auth file names. Update '
        'the auth file, or restore the test id in the application.',
  ),

  /// The authentication exchange never happened, or did not answer as
  /// declared.
  authRequestFailed(
    'AUTH_REQUEST_FAILED',
    PrerequisiteClass.externalService,
    'The application could not complete its authentication request. Check '
        'that the backend the build points at is reachable from the device.',
  ),

  /// The application went somewhere that cannot be driven deterministically.
  authPathNotSupported(
    'AUTH_PATH_NOT_SUPPORTED',
    PrerequisiteClass.applicationControlled,
    'The application chose a one-time-code path, which needs a real message '
        'and cannot be automated without bypassing authentication. Use an '
        'account whose sign-in the auth file can drive.',
  ),

  /// Authentication worked and the authenticated route was not reached.
  authenticatedStateNotReached(
    'AUTHENTICATED_STATE_NOT_REACHED',
    PrerequisiteClass.applicationControlled,
    'Authentication succeeded and the application did not reach the route '
        'the auth file verifies. Check the device location service and the '
        'permissions the auth file declares.',
  ),

  /// Device, build, profile, permissions, or the wrong application.
  environmentPrerequisite(
    'ENVIRONMENT_PREREQUISITE',
    PrerequisiteClass.devicePrerequisite,
    'The environment could not run auth setup. The preflight rows above say '
        'which prerequisite and what to do about it.',
  );

  const AuthSetupFailure(this.wire, this.klass, this.remedy);

  final String wire;
  final PrerequisiteClass klass;

  /// What a person should do. Carried on the value rather than passed in,
  /// so a classification can never be reported without one.
  final String remedy;
}

/// What auth setup did, and what it can say about it.
///
/// Serialised through an **allow-list** of keys. That is E-04's pattern
/// and E-04's reasoning: a deny-list only ever catches the secrets
/// somebody remembered. Nothing here carries a URL, a body, a header, a
/// UI tree, an image, a device serial or a credential.
@immutable
final class AuthSetupResult {
  const AuthSetupResult({
    required this.outcome,
    required this.loginPerformed,
    this.failure,
    this.detail = '',
    this.remedy = '',
    this.route,
    this.routeHistory = const [],
    this.elementVerified = false,
    this.request,
    this.durationMs = 0,
    this.secretsUsed = const [],
    this.appId,
    this.appVersion,
    this.buildMode,
    this.deviceModel,
  });

  final AuthSetupOutcome outcome;
  final AuthSetupFailure? failure;

  /// What was found. Never a credential: every value that could carry one
  /// is a [Secret], whose `toString` is the marker.
  final String detail;

  final String remedy;

  /// The route the application's own router last chose.
  final String? route;

  /// Every route it passed through, which is what proves a cold start
  /// reached the authenticated route without going by way of the login
  /// screen.
  final List<String> routeHistory;

  /// False when the device was already authenticated. Recorded so nobody
  /// reads a skipped verification term as a satisfied one.
  final bool loginPerformed;

  final bool elementVerified;

  /// Endpoint, status and whether it held. `ApiExpectationOutcome`
  /// serialises no body, no headers and no URL query.
  final ApiExpectationOutcome? request;

  final int durationMs;

  /// References only.
  final List<SecretRef> secretsUsed;

  final String? appId;
  final String? appVersion;
  final String? buildMode;

  /// The model, never the serial.
  final String? deviceModel;

  bool get succeeded => outcome == AuthSetupOutcome.succeeded;

  /// 0 or 2, and never 1.
  ///
  /// Exit 1 means the application is wrong. Auth setup judges no screen,
  /// so it is never in a position to say that; every failure is "the run
  /// is wrong", which is what 2 has always meant here.
  int get exitCode => succeeded ? 0 : 2;

  Map<String, Object?> toJson() => {
        'outcome': outcome.wire,
        if (failure != null) 'classification': failure!.wire,
        if (detail.isNotEmpty) 'detail': detail,
        if (remedy.isNotEmpty) 'remedy': remedy,
        'route': route,
        'routeHistory': routeHistory,
        'loginPerformed': loginPerformed,
        'elementVerified': elementVerified,
        if (request != null) 'request': request!.toJson(),
        'durationMs': durationMs,
        'secretsUsed': [for (final ref in secretsUsed) ref.toString()],
        'appId': appId,
        'appVersion': appVersion,
        'buildMode': buildMode,
        'deviceModel': deviceModel,
      };
}
```

**Note for the implementer:** the allow-list test asserts an exact key set for a *successful* result. `appVersion` and `buildMode` are emitted as `null` there, which the test's key-set comparison tolerates. If `_polluted()` omits them and the difference test fails, emit them unconditionally as above — do not make them conditional.

- [ ] **Step 4: Export it**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`:

```dart
export 'src/auth/auth_result.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_leakage_test.dart`
Expected: PASS, 10 tests.

- [ ] **Step 6: Verify**

Run: `cd packages/flutter_testsmith_engine && dart test` then from root `dart analyze --fatal-infos`
Expected: green. **Do not commit.**

---

## Task 6: The verdict, as one pure function

This is where §9.0's precedence lives, and it is pure so that the whole state matrix is tested without a handset.

**Files:**
- Create: `packages/flutter_testsmith_engine/lib/src/auth/auth_verification.dart`
- Test: `packages/flutter_testsmith_engine/test/auth_verification_test.dart`
- Modify: `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`

**Interfaces:**
- Consumes: `AuthFile`, `AuthVerify`, `AuthUiState` (Task 4); `AuthSetupFailure` (Task 5); `ApiExpectationOutcome` (existing).
- Produces:
  - `final class AuthObservations` — `AuthObservations({required String? route, required List<String> routeHistory, required bool loginPerformed, required bool elementPresent, ApiExpectationOutcome? request, bool invalidCredentialVisible = false, bool loginUiMissing = false, String? missingElementId, bool environmentBlocked = false, bool secretMissing = false, String? handshakeAppId})`
  - `AuthSetupFailure? classifyAuthSetup({required AuthFile file, required AuthObservations seen})` — returns null when everything held.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_engine/test/auth_verification_test.dart`:

```dart
// The whole state matrix, decided without a handset.
//
// Every case in the design's section 11 is here, plus the precedence in
// section 9.0 - because more than one rule can be true at once, and the
// most specific answer is the most useful one.

import 'package:test/test.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.app
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/onboarding, /login]
login:
  - inputSecret: {id: pin_field, secret: pin}
  - tap: {id: continue_button}
verify:
  route: /home
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location, /otp-verification, /registration-otp]
  invalidCredentialOn: {route: /secure-login, element: login.pin_error}
''';

final AuthFile file = AuthFile.parse(_yaml, source: 'test');

ApiExpectationOutcome _request({required bool satisfied}) =>
    ApiExpectationOutcome(
      endpoint: 'POST /login/consumer',
      status: satisfied ? 200 : 401,
      failures: satisfied ? const [] : const ['expected 200, received 401'],
    );

AuthObservations _seen({
  String? route = '/home',
  List<String> routeHistory = const ['/', '/login', '/home'],
  bool loginPerformed = true,
  bool elementPresent = true,
  ApiExpectationOutcome? request,
  bool invalidCredentialVisible = false,
  bool loginUiMissing = false,
  bool environmentBlocked = false,
  bool secretMissing = false,
  String? handshakeAppId = 'com.example.app',
}) =>
    AuthObservations(
      route: route,
      routeHistory: routeHistory,
      loginPerformed: loginPerformed,
      elementPresent: elementPresent,
      request: request ?? _request(satisfied: true),
      invalidCredentialVisible: invalidCredentialVisible,
      loginUiMissing: loginUiMissing,
      environmentBlocked: environmentBlocked,
      secretMissing: secretMissing,
      handshakeAppId: handshakeAppId,
    );

void main() {
  group('case A - a real login succeeded', () {
    test('every term held, so there is no failure', () {
      expect(classifyAuthSetup(file: file, seen: _seen()), isNull);
    });
  });

  group('case B - already authenticated', () {
    test('a cold start that reached /home without passing a signed-out '
        'route needs no login request', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          loginPerformed: false,
          routeHistory: const ['/', '/home'],
          request: null,
        ),
      );
      expect(verdict, isNull);
    });

    test('a guest who navigated to /home is not accepted as a session', () {
      // /home is guest-browsable. What a guest cannot do is *start*
      // there, so the route history is what carries the proof.
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          loginPerformed: false,
          routeHistory: const ['/', '/login', '/home'],
          request: null,
        ),
      );
      expect(verdict, AuthSetupFailure.authenticatedStateNotReached);
    });
  });

  group('case C - invalid credentials', () {
    test('the application saying so is what decides it', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(
          route: '/secure-login',
          invalidCredentialVisible: true,
          request: _request(satisfied: false),
        ),
      );
      expect(verdict, AuthSetupFailure.invalidCredential);
    });
  });

  group('case D - the wrong application', () {
    test('a handshake naming another package is an environment failure', () {
      final verdict = classifyAuthSetup(
        file: file,
        seen: _seen(handshakeAppId: 'com.example.other'),
      );
      expect(verdict, AuthSetupFailure.environmentPrerequisite);
    });

    test('so is a blocked preflight', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(environmentBlocked: true)),
        AuthSetupFailure.environmentPrerequisite,
      );
    });
  });

  group('case E - the login UI changed', () {
    test('a missing element stops it', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(loginUiMissing: true, route: '/login'),
        ),
        AuthSetupFailure.loginUiNotFound,
      );
    });
  });

  group('case F - authenticated but the route was not reached', () {
    test('/set-location is named rather than called an auth failure', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/set-location')),
        AuthSetupFailure.authenticatedStateNotReached,
      );
    });

    test('a route event without a rendered element is not enough', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(elementPresent: false)),
        AuthSetupFailure.authenticatedStateNotReached,
      );
    });
  });

  group('a one-time-code path', () {
    test('is refused by name rather than timing out', () {
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/otp-verification')),
        AuthSetupFailure.authPathNotSupported,
      );
      expect(
        classifyAuthSetup(file: file, seen: _seen(route: '/registration-otp')),
        AuthSetupFailure.authPathNotSupported,
      );
    });
  });

  group('a failed authentication request', () {
    test('is reported when the application showed no error of its own', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', request: _request(satisfied: false)),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });

    test('and when the request never happened at all', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', request: null),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });
  });

  group('precedence - section 9.0, pair by pair', () {
    test('environment outranks a missing secret', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(environmentBlocked: true, secretMissing: true),
        ),
        AuthSetupFailure.environmentPrerequisite,
      );
    });

    test('a missing secret outranks a missing login element', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(secretMissing: true, loginUiMissing: true),
        ),
        AuthSetupFailure.secretMissing,
      );
    });

    test('a missing login element outranks an unsupported path', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(loginUiMissing: true, route: '/otp-verification'),
        ),
        AuthSetupFailure.loginUiNotFound,
      );
    });

    test('an unsupported path outranks an invalid credential', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/otp-verification',
            invalidCredentialVisible: true,
          ),
        ),
        AuthSetupFailure.authPathNotSupported,
      );
    });

    test('an invalid credential outranks a failed request', () {
      // "Your PIN is wrong" is actionable. "The login request answered
      // 401" is the same news in a form that sends somebody to a backend.
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(
            route: '/secure-login',
            invalidCredentialVisible: true,
            request: _request(satisfied: false),
          ),
        ),
        AuthSetupFailure.invalidCredential,
      );
    });

    test('a failed request outranks the route not being reached', () {
      expect(
        classifyAuthSetup(
          file: file,
          seen: _seen(route: '/login', request: _request(satisfied: false)),
        ),
        AuthSetupFailure.authRequestFailed,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_verification_test.dart`
Expected: FAIL — `classifyAuthSetup` and `AuthObservations` are undefined.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_engine/lib/src/auth/auth_verification.dart`:

```dart
import 'package:meta/meta.dart';

import '../validation/api_expectation.dart';
import 'auth_flow.dart';
import 'auth_result.dart';

/// Everything the runner saw, and nothing it inferred.
///
/// A plain record of observations so that the decision below is a pure
/// function: the whole state matrix is then testable without a handset,
/// which is the same split `doctor` and E-04's preflight already use -
/// facts from the CLI, judgements in the engine.
@immutable
final class AuthObservations {
  const AuthObservations({
    required this.route,
    required this.routeHistory,
    required this.loginPerformed,
    required this.elementPresent,
    this.request,
    this.invalidCredentialVisible = false,
    this.loginUiMissing = false,
    this.missingElementId,
    this.environmentBlocked = false,
    this.secretMissing = false,
    this.handshakeAppId,
  });

  /// The route the application's own router last chose.
  final String? route;

  /// Every route it passed through since launch.
  final List<String> routeHistory;

  final bool loginPerformed;

  /// Whether the verify block's element was on the final screen.
  final bool elementPresent;

  /// The application's own authentication exchange, when one happened.
  final ApiExpectationOutcome? request;

  /// Whether the application's own "that credential was wrong" state is
  /// showing, as the auth file declares it.
  final bool invalidCredentialVisible;

  /// Whether a step could not find the element it named.
  final bool loginUiMissing;
  final String? missingElementId;

  final bool environmentBlocked;
  final bool secretMissing;

  /// What the handshake said the application is.
  final String? handshakeAppId;
}

/// Why setup did not work, or null when it did.
///
/// The order is the specification's section 9.0 and is load-bearing:
/// more than one rule can be true at once, and the most specific answer
/// is the most useful one.
AuthSetupFailure? classifyAuthSetup({
  required AuthFile file,
  required AuthObservations seen,
}) {
  // 1. Nothing below could be believed.
  if (seen.environmentBlocked) {
    return AuthSetupFailure.environmentPrerequisite;
  }
  if (seen.handshakeAppId != null && seen.handshakeAppId != file.appId) {
    return AuthSetupFailure.environmentPrerequisite;
  }

  // 2. Nothing was ever typed.
  if (seen.secretMissing) return AuthSetupFailure.secretMissing;

  // 3. The flow could not be driven.
  if (seen.loginUiMissing) return AuthSetupFailure.loginUiNotFound;

  // 4. The application went somewhere we refuse rather than time out on.
  //
  // `notOn` routes that are not the invalid-credential route are paths
  // the auth file has declared unsupported; the OTP routes are the
  // instance that exists today.
  final route = seen.route;
  if (route != null &&
      file.verify.notOn.contains(route) &&
      _isOneTimeCodeRoute(route)) {
    return AuthSetupFailure.authPathNotSupported;
  }

  // 5. The application itself said the credential was wrong.
  final invalid = file.verify.invalidCredentialOn;
  if (invalid != null &&
      seen.invalidCredentialVisible &&
      route == invalid.route) {
    return AuthSetupFailure.invalidCredential;
  }

  // 6. The authentication request did not answer as declared. Only
  //    meaningful when a login was actually attempted - on the
  //    already-authenticated path there is no request to judge, and a
  //    skipped term must not read as a satisfied one.
  if (seen.loginPerformed && file.verify.request != null) {
    final request = seen.request;
    if (request == null || !request.satisfied) {
      return AuthSetupFailure.authRequestFailed;
    }
  }

  // 7. Everything worked and the authenticated state did not arrive.
  if (route != file.verify.route) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }
  if (!seen.elementPresent) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }

  // A cold start that reached the authenticated route without passing a
  // signed-out route is the proof of a session, and it is the
  // application's own router that supplies it. A run that got there by
  // some other path - a guest browsing to a guest-browsable route - is
  // not accepted as evidence.
  if (!seen.loginPerformed &&
      seen.routeHistory.any(file.signedOutOn.contains)) {
    return AuthSetupFailure.authenticatedStateNotReached;
  }

  return null;
}

/// Whether a route is a one-time-code screen.
///
/// Named by suffix rather than by an exact list, so an application that
/// spells its OTP route differently is still recognised. It only ever
/// *upgrades* a route the auth file already declared unsupported, so a
/// false positive here cannot turn a failure into a pass.
bool _isOneTimeCodeRoute(String route) =>
    route.contains('otp') || route.contains('one-time');
```

- [ ] **Step 4: Export it**

In `packages/flutter_testsmith_engine/lib/flutter_testsmith_engine.dart`:

```dart
export 'src/auth/auth_verification.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_engine && dart test test/auth_verification_test.dart`
Expected: PASS, 19 tests.

- [ ] **Step 6: Verify**

Run: `cd packages/flutter_testsmith_engine && dart test` then from root `dart analyze --fatal-infos`
Expected: green. **Do not commit.**

---

## Task 7: Auth preflight, composed from E-04's checks

**Files:**
- Create: `packages/flutter_testsmith_cli/lib/src/auth_preflight.dart`
- Test: `packages/flutter_testsmith_cli/test/auth_preflight_test.dart`
- Modify: `packages/flutter_testsmith_cli/lib/src/suite_runner.dart` (extract `grantPermissions`)

**Interfaces:**
- Consumes: `AuthFile` (Task 4); existing `checkAppBuild`, `checkDeviceAttached`, `checkProfileMatch`, `checkPermissions`, `checkNetworkInterface`, `PreflightCheck`, `PreflightReport`, `DeviceEnvironment`, `AdbDevice`, `DeviceProfile`, `DeviceFacts`.
- Produces:
  - `class AuthPreflightRunner` — `AuthPreflightRunner({required AuthFile file, required Directory projectDirectory, required DeviceProfile profile, required DeviceEnvironment deviceEnvironment, required List<AdbDevice> attachedDevices, required String? requestedSerial, required DeviceFacts deviceFacts, required bool flutterOnPath})` with `Future<PreflightReport> run()`.
  - In `suite_runner.dart`: `Future<void> grantPermissions({required String appId, required List<String> permissions, required DeviceController device, required void Function(String) log})`.

- [ ] **Step 1: Extract `grantPermissions`, preserving E-04 behaviour**

In `packages/flutter_testsmith_cli/lib/src/suite_runner.dart`, replace the body of `grantDeclaredPermissions` so it delegates, and add the new function above it:

```dart
/// Grants [permissions] to [appId], reporting each and raising nothing.
///
/// Extracted from [grantDeclaredPermissions] so auth setup arranges its
/// device exactly as a suite does. A failure is logged rather than
/// thrown: the permission check that follows is what decides whether the
/// run can proceed, and it gives a better message than this could.
Future<void> grantPermissions({
  required String appId,
  required List<String> permissions,
  required DeviceController device,
  required void Function(String) log,
}) async {
  for (final permission in permissions) {
    try {
      await device.grantPermission(appId, permission);
      log('  granted $permission');
    } catch (error) {
      log('  ! could not grant $permission: $error');
    }
  }
}

Future<void> grantDeclaredPermissions({
  required SuiteFile suite,
  required Directory projectDirectory,
  required DeviceController device,
  required void Function(String) log,
}) async {
  if (suite.devicePermissions.isEmpty) return;

  final appId = declaredAppId(suite, projectDirectory);
  if (appId == null) return;

  await grantPermissions(
    appId: appId,
    permissions: suite.devicePermissions,
    device: device,
    log: log,
  );
}
```

- [ ] **Step 2: Confirm E-04 still passes after the extraction**

Run: `cd packages/flutter_testsmith_cli && dart test`
Expected: unchanged, all green. This proves the refactor is behaviour-preserving before anything is built on it.

- [ ] **Step 3: Write the failing test**

Create `packages/flutter_testsmith_cli/test/auth_preflight_test.dart`:

```dart
// Auth setup asks E-04's questions, using E-04's check functions.
//
// Two things differ from a suite's preflight and both are deliberate:
// there is no mock API to check, because auth setup runs against the
// real backend; and that backend is `deferred` rather than probed - a
// probe from the host would be a network call the platform otherwise
// never makes, and it would prove only that the *host* can reach it.

import 'dart:io';

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/auth_preflight.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.app
device:
  profile: p
  permissions: [android.permission.ACCESS_FINE_LOCATION]
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - tap: {id: continue_button}
verify: {route: /home, element: home.body}
''';

class FakeEnvironment implements DeviceEnvironment {
  FakeEnvironment({
    this.installed = true,
    this.permissions = const {'android.permission.ACCESS_FINE_LOCATION': true},
    this.network = NetworkInterfaceState.up,
  });

  final bool installed;
  final Map<String, bool> permissions;
  final NetworkInterfaceState network;

  @override
  Future<bool> isInstalled(String appId) async => installed;

  @override
  Future<Map<String, bool>> runtimePermissions(String appId) async =>
      permissions;

  @override
  Future<NetworkInterfaceState> networkInterface() async => network;
}

late Directory _project;

Future<PreflightReport> _run({
  FakeEnvironment? environment,
  List<AdbDevice> attached = const [AdbDevice(serial: 'S1', model: 'M')],
  bool flutterOnPath = true,
}) =>
    AuthPreflightRunner(
      file: AuthFile.parse(_yaml, source: 'auth.yaml'),
      projectDirectory: _project,
      profile: const DeviceProfile(id: 'p'),
      deviceEnvironment: environment ?? FakeEnvironment(),
      attachedDevices: attached,
      requestedSerial: 'S1',
      deviceFacts: const DeviceFacts(),
      flutterOnPath: flutterOnPath,
    ).run();

void main() {
  setUp(() {
    _project = Directory.systemTemp.createTempSync('auth_preflight');
    addTearDown(() => _project.deleteSync(recursive: true));
    File('${_project.path}/lib/main_uat.dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
  });

  test('a ready machine blocks nothing and exits 0', () async {
    final report = await _run();
    expect(report.isBlocked, isFalse);
    expect(report.exitCode, 0);
  });

  test('it checks the build, the device, the profile, the permissions, '
      'the network and the backend', () async {
    final names = (await _run()).checks.map((c) => c.name).toList();
    expect(names, contains('application build'));
    expect(names, contains('device'));
    expect(names, contains('device profile'));
    expect(names, contains('permissions'));
    expect(names, contains('network interface'));
    expect(names, contains('authentication backend'));
  });

  test('and no mock API, because auth setup serves no fixtures', () async {
    final names = (await _run()).checks.map((c) => c.name).toList();
    expect(names, isNot(contains('mock API')));
  });

  test('the backend is deferred, never probed', () async {
    final backend = (await _run())
        .checks
        .firstWhere((c) => c.name == 'authentication backend');
    expect(backend.outcome, PreflightOutcome.deferred);
    expect(backend.klass, PrerequisiteClass.externalService);
    expect(backend.isBlocking, isFalse);
  });

  test('a denied permission blocks, and exits 2', () async {
    final report = await _run(
      environment: FakeEnvironment(
        permissions: const {
          'android.permission.ACCESS_FINE_LOCATION': false,
        },
      ),
    );
    expect(report.isBlocked, isTrue);
    expect(report.exitCode, 2);
  });

  test('no network interface blocks', () async {
    final report = await _run(
      environment: FakeEnvironment(network: NetworkInterfaceState.down),
    );
    expect(report.isBlocked, isTrue);
  });

  test('no device attached blocks', () async {
    expect((await _run(attached: const [])).isBlocked, isTrue);
  });

  test('every blocking check carries a remedy', () async {
    final report = await _run(attached: const []);
    for (final blocker in report.blockers) {
      expect(blocker.remedy, isNotEmpty, reason: blocker.name);
    }
  });

  test('nothing in the report names the serial or a credential', () async {
    final text = (await _run()).toJson().toString();
    expect(text, isNot(contains('S1')));
    expect(text, isNot(contains('MYTEST_AUTH_PIN')));
  });
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_preflight_test.dart`
Expected: FAIL — `auth_preflight.dart` does not exist.

**Note for the implementer:** `AdbDevice`, `DeviceProfile` and `DeviceFacts` constructors may differ from what this test assumes. Read `packages/flutter_testsmith_engine/lib/src/device/device_profile.dart` and the existing `packages/flutter_testsmith_cli/test/preflight_runner_test.dart`, and use exactly the constructor forms that file already uses.

- [ ] **Step 5: Write the implementation**

Create `packages/flutter_testsmith_cli/lib/src/auth_preflight.dart`:

```dart
import 'dart:io';

import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// Answers "could this machine authenticate?" before it tries to.
///
/// Composed from E-04's pure check functions rather than inheriting
/// [PreflightRunner], which is built around a `SuiteFile`. An auth file
/// is not a suite and pretending it is would be worse than composing.
///
/// Two differences from a suite's preflight, both deliberate: there is no
/// mock API, because auth setup serves no fixtures and talks to the real
/// backend; and that backend is **deferred** rather than probed.
class AuthPreflightRunner {
  const AuthPreflightRunner({
    required this.file,
    required this.projectDirectory,
    required this.profile,
    required this.deviceEnvironment,
    required this.attachedDevices,
    required this.requestedSerial,
    required this.deviceFacts,
    required this.flutterOnPath,
  });

  final AuthFile file;
  final Directory projectDirectory;
  final DeviceProfile profile;
  final DeviceEnvironment deviceEnvironment;
  final List<AdbDevice> attachedDevices;
  final String? requestedSerial;
  final DeviceFacts deviceFacts;
  final bool flutterOnPath;

  Future<PreflightReport> run() async {
    final target = file.app.target;
    final targetExists = target == null ||
        File('${projectDirectory.path}/$target').existsSync();

    final device = checkDeviceAttached(
      attached: attachedDevices,
      requested: requestedSerial,
    );
    final profileMatch =
        checkProfileMatch(profile: profile, facts: deviceFacts);

    // Only read the handset once it is established to be the right
    // handset. Reading the wrong one would answer a question nobody
    // asked, and the two checks above are pure.
    final readable = !device.isBlocking && !profileMatch.isBlocking;

    final granted = readable
        ? await deviceEnvironment.runtimePermissions(file.appId)
        : const <String, bool>{};
    final network = readable
        ? await deviceEnvironment.networkInterface()
        : NetworkInterfaceState.unknown;

    return PreflightReport([
      checkAppBuild(
        target: target,
        targetExists: targetExists,
        flutterOnPath: flutterOnPath,
      ),
      device,
      profileMatch,
      checkPermissions(
        appId: file.appId,
        required: file.devicePermissions,
        granted: granted,
      ),
      checkNetworkInterface(network),
      _checkBackend(),
    ]);
  }

  /// The one external service this platform ever addresses.
  ///
  /// Deferred rather than probed. A probe from the host would be a
  /// network call the platform otherwise never makes, and it would
  /// establish only that the *host* can reach the backend - not the
  /// device, which is what matters. A backend that is not there surfaces
  /// as AUTH_REQUEST_FAILED, from the application's own attempt, which is
  /// the honest place for it to surface.
  PreflightCheck _checkBackend() => const PreflightCheck.deferred(
        'authentication backend',
        klass: PrerequisiteClass.externalService,
        detail: 'the build being launched signs in against a real backend; '
            'whether it answered is knowable only from the application\'s own '
            'request, and is reported as the setup result',
      );
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_preflight_test.dart`
Expected: PASS, 10 tests.

- [ ] **Step 7: Verify**

Run: `cd packages/flutter_testsmith_cli && dart test` then from root `dart analyze --fatal-infos`
Expected: green, and the E-04 preflight and suite tests unchanged. **Do not commit.**

---

## Task 8: The runner

**Files:**
- Create: `packages/flutter_testsmith_cli/lib/src/auth_runner.dart`
- Test: `packages/flutter_testsmith_cli/test/auth_runner_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1–7; existing `AppSession`, `ElementLocator`, `ApiExpectationEvaluator`, `SessionManager`, `AdbDeviceController`, `Output`.
- Produces:
  - `abstract interface class AuthDriver` — the seam that makes this testable without a handset. Methods: `Future<String?> currentRoute()`, `List<String> routeHistory()`, `Future<void> tap(String elementId)`, `Future<void> inputSecret(String elementId, Secret secret)`, `Future<void> waitForSettle(Duration timeout)`, `Future<void> awaitRoute(String route, Duration timeout)`, `Future<bool> hasElement(String elementId)`, `Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step)`, `Future<({String appId, String? version, String? buildMode})> identity()`, `Future<void> dispose()`.
  - `class AuthRunner` — `AuthRunner({required AuthFile file, required SecretResolver secrets, required AuthDriver driver, required void Function(String) log, String? deviceModel})` with `Future<AuthSetupResult> run()`.

`AuthRunner` never touches adb or `flutter run`. `AppSession` is adapted to `AuthDriver` in Task 9, which keeps every decision in this task unit-testable.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_cli/test/auth_runner_test.dart`:

```dart
// The lifecycle, driven against a scripted application.
//
// The driver is a seam rather than a handset, so every branch - already
// authenticated, a wrong PIN, a missing element, a teardown after a
// failure - is a test that runs in milliseconds on any machine. The
// handset proves the wiring; this proves the decisions.

import 'package:test/test.dart';
import 'package:flutter_testsmith_cli/src/auth_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

const String _seededPin = 'SEEDED_PIN_9f2a41c8';
const String _seededMobile = '9876543210';

const String _yaml = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.app
device: {profile: p}
secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN
signedOutOn: [/onboarding, /login]
onboarding:
  - tap: {id: onboarding.get_started}
login:
  - expectScreen: {id: /login}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - expectScreen: {id: /secure-login}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}
verify:
  route: /home
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location, /otp-verification]
  invalidCredentialOn: {route: /secure-login, element: secure_login.pin_error}
''';

final AuthFile _file = AuthFile.parse(_yaml, source: 'auth.yaml');

class MapResolver implements SecretResolver {
  MapResolver(this._values);
  final Map<String, String> _values;

  @override
  bool isPresent(SecretRef ref) => (_values[ref.name] ?? '').isNotEmpty;

  @override
  Secret resolve(SecretRef ref) {
    final value = _values[ref.name];
    if (value == null || value.isEmpty) throw MissingSecretException(ref);
    return Secret(value);
  }
}

/// An application that follows a script of routes.
class ScriptedDriver implements AuthDriver {
  ScriptedDriver({
    required this.routes,
    this.missingElements = const {},
    this.presentElements = const {'home.body', 'secure_login.pin_error'},
    this.exchange,
    this.appId = 'com.example.app',
  });

  /// Routes the application moves through, one per `tap`.
  final List<String> routes;
  final Set<String> missingElements;
  final Set<String> presentElements;
  final ApiExpectationOutcome? exchange;
  final String appId;

  int _index = 0;
  final List<String> _history = [];
  final List<String> actions = [];
  bool disposed = false;

  @override
  Future<String?> currentRoute() async {
    final route = routes[_index.clamp(0, routes.length - 1)];
    if (_history.isEmpty || _history.last != route) _history.add(route);
    return route;
  }

  @override
  List<String> routeHistory() => List.unmodifiable(_history);

  @override
  Future<void> tap(String elementId) async {
    if (missingElements.contains(elementId)) {
      throw ElementNotFoundException(testId: elementId, available: const []);
    }
    actions.add('tap $elementId');
    if (_index < routes.length - 1) _index++;
    await currentRoute();
  }

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {
    if (missingElements.contains(elementId)) {
      throw ElementNotFoundException(testId: elementId, available: const []);
    }
    // Deliberately records the rendering, not the value: if this ever
    // prints the credential, the leakage test below catches it.
    actions.add('inputSecret $elementId $secret');
  }

  @override
  Future<void> waitForSettle(Duration timeout) async {}

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {
    await currentRoute();
  }

  @override
  Future<bool> hasElement(String elementId) async =>
      presentElements.contains(elementId);

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async =>
      exchange;

  @override
  Future<({String appId, String? version, String? buildMode})> identity() async =>
      (appId: appId, version: '1.0.6', buildMode: 'debug');

  @override
  Future<void> dispose() async => disposed = true;
}

ApiExpectationOutcome _ok() => const ApiExpectationOutcome(
      endpoint: 'POST /login/consumer',
      status: 200,
      failures: [],
    );

Future<({AuthSetupResult result, ScriptedDriver driver, List<String> log})> _run(
  ScriptedDriver driver, {
  Map<String, String> secrets = const {
    'MYTEST_AUTH_MOBILE': _seededMobile,
    'MYTEST_AUTH_PIN': _seededPin,
  },
}) async {
  final log = <String>[];
  final result = await AuthRunner(
    file: _file,
    secrets: MapResolver(secrets),
    driver: driver,
    log: log.add,
    deviceModel: 'SM-M127G',
  ).run();
  return (result: result, driver: driver, log: log);
}

void main() {
  group('a signed-out device', () {
    test('drives the real login and succeeds', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      expect(run.result.succeeded, isTrue);
      expect(run.result.exitCode, 0);
      expect(run.result.loginPerformed, isTrue);
      expect(run.result.route, '/home');
      expect(run.result.elementVerified, isTrue);
    });

    test('and enters at onboarding when that is where it landed', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));
      expect(run.driver.actions.first, 'tap onboarding.get_started');
    });

    test('and skips onboarding when it landed on the login form', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));
      expect(run.driver.actions, isNot(contains('tap onboarding.get_started')));
      expect(run.result.succeeded, isTrue);
    });
  });

  group('an already-authenticated device', () {
    test('verifies without logging in again', () async {
      final run = await _run(ScriptedDriver(routes: ['/home']));

      expect(run.result.succeeded, isTrue);
      expect(run.result.loginPerformed, isFalse);
      expect(
        run.driver.actions,
        isEmpty,
        reason: 'no tap and no credential on an already-authenticated device',
      );
    });

    test('and no secret is resolved at all', () async {
      // The value must be in memory only for the interaction that needs
      // it, and on this path there is no such interaction.
      final run = await _run(ScriptedDriver(routes: ['/home']));
      expect(run.result.secretsUsed, isEmpty);
    });
  });

  group('failures', () {
    test('a missing secret stops before anything is driven', () async {
      final run = await _run(
        ScriptedDriver(routes: ['/login', '/home']),
        secrets: const {'MYTEST_AUTH_MOBILE': _seededMobile},
      );

      expect(run.result.failure, AuthSetupFailure.secretMissing);
      expect(run.result.exitCode, 2);
      expect(run.driver.actions, isEmpty);
    });

    test('an invalid credential is classified from the application\'s own '
        'error state', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/secure-login'],
        exchange: const ApiExpectationOutcome(
          endpoint: 'POST /login/consumer',
          status: 401,
          failures: ['expected 200, received 401'],
        ),
      ));

      expect(run.result.failure, AuthSetupFailure.invalidCredential);
    });

    test('a missing element is LOGIN_UI_NOT_FOUND', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        missingElements: {'secure_login.pin_field'},
        exchange: _ok(),
      ));

      expect(run.result.failure, AuthSetupFailure.loginUiNotFound);
    });

    test('landing on /set-location is not called an auth failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/set-location'],
        exchange: _ok(),
      ));

      expect(run.result.failure, AuthSetupFailure.authenticatedStateNotReached);
      expect(run.result.remedy, isNotEmpty);
    });

    test('the wrong application is an environment failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/home'],
        appId: 'com.example.other',
      ));

      expect(run.result.failure, AuthSetupFailure.environmentPrerequisite);
    });
  });

  group('cleanup', () {
    test('the session is disposed after success', () async {
      final run = await _run(ScriptedDriver(routes: ['/home']));
      expect(run.driver.disposed, isTrue);
    });

    test('and after a failure', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/set-location'],
        exchange: _ok(),
      ));
      expect(run.driver.disposed, isTrue);
    });

    test('and after a missing secret, which never launched anything',
        () async {
      final run = await _run(
        ScriptedDriver(routes: ['/login']),
        secrets: const {},
      );
      expect(run.result.failure, AuthSetupFailure.secretMissing);
    });
  });

  group('leakage', () {
    test('no credential reaches the log', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/onboarding', '/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      final text = run.log.join('\n');
      expect(text, isNot(contains(_seededPin)));
      expect(text, isNot(contains(_seededMobile)));
      expect(text, contains('env:MYTEST_AUTH_PIN'));
    });

    test('nor the recorded actions', () async {
      final run = await _run(ScriptedDriver(
        routes: ['/login', '/secure-login', '/home'],
        exchange: _ok(),
      ));

      final text = run.driver.actions.join('\n');
      expect(text, isNot(contains(_seededPin)));
      expect(text, contains(redactionMarker));
    });

    test('nor the result, on any path', () async {
      for (final driver in [
        ScriptedDriver(routes: ['/home']),
        ScriptedDriver(
          routes: ['/login', '/secure-login', '/home'],
          exchange: _ok(),
        ),
        ScriptedDriver(
          routes: ['/login', '/secure-login', '/secure-login'],
          exchange: _ok(),
        ),
      ]) {
        final run = await _run(driver);
        final text = run.result.toJson().toString();
        expect(text, isNot(contains(_seededPin)));
        expect(text, isNot(contains(_seededMobile)));
      }
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_runner_test.dart`
Expected: FAIL — `auth_runner.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_testsmith_cli/lib/src/auth_runner.dart`:

```dart
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

/// What the runner needs an application to do.
///
/// An interface rather than an [AppSession] so every decision in
/// [AuthRunner] is testable without a handset - the same seam
/// `DeviceEnvironment` gives preflight, for the same reason. The adapter
/// onto a real session lives with the command.
abstract interface class AuthDriver {
  /// The route the application's own router has currently chosen.
  Future<String?> currentRoute();

  /// Every route it has passed through since launch.
  List<String> routeHistory();

  Future<void> tap(String elementId);

  /// Types a credential. The value reaches the device and nothing else.
  Future<void> inputSecret(String elementId, Secret secret);

  Future<void> waitForSettle(Duration timeout);

  Future<void> awaitRoute(String route, Duration timeout);

  Future<bool> hasElement(String elementId);

  /// The application's own exchange matching [step], or null.
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step);

  /// What the handshake said the application is.
  Future<({String appId, String? version, String? buildMode})> identity();

  Future<void> dispose();
}

/// Establishes an authenticated state through the real login UI.
///
/// Holds no adb and no `flutter run`: it decides, and [AuthDriver] acts.
class AuthRunner {
  AuthRunner({
    required this.file,
    required this.secrets,
    required this.driver,
    required this.log,
    this.deviceModel,
  });

  final AuthFile file;
  final SecretResolver secrets;
  final AuthDriver driver;
  final void Function(String) log;
  final String? deviceModel;

  Future<AuthSetupResult> run() async {
    final watch = Stopwatch()..start();

    var loginPerformed = false;
    var loginUiMissing = false;
    String? missingElementId;
    ApiExpectationOutcome? exchange;
    final used = <SecretRef>[];

    try {
      final identity = await driver.identity();

      // Which build answered. Asked before anything is driven, because
      // every observation below is about whichever application this is.
      if (identity.appId != file.appId) {
        log('  ! the handshake reports ${identity.appId}, and this auth file '
            'declares ${file.appId}');
        return _result(
          failure: AuthSetupFailure.environmentPrerequisite,
          detail: 'the application that answered is ${identity.appId}, not '
              '${file.appId}',
          route: await driver.currentRoute(),
          loginPerformed: false,
          elementVerified: false,
          watch: watch,
          identity: identity,
          used: used,
        );
      }

      final landed = await driver.currentRoute();
      log('› the application chose "$landed"');

      if (file.signedOutOn.contains(landed)) {
        // A session has to be established, so the real UI is driven.
        try {
          if (landed != null &&
              file.onboarding.isNotEmpty &&
              landed != _firstExpectedRoute(file.login)) {
            await _drive(file.onboarding, used);
          }
          await _drive(file.login, used);
          loginPerformed = true;
        } on ElementNotFoundException catch (error) {
          loginUiMissing = true;
          missingElementId = error.testId;
          log('  ✗ the login UI does not carry "${error.testId}"');
        }
      } else {
        log('› already authenticated; no credential will be used');
      }

      if (!loginUiMissing) {
        // Wait for the authenticated route, but never longer than
        // declared. Not reaching it is a verdict, not an exception.
        try {
          await driver.awaitRoute(file.verify.route, file.verify.timeout);
        } on Object {
          // Reported by classification below, from the route actually on.
        }
      }

      final route = await driver.currentRoute();
      final request = file.verify.request;
      if (loginPerformed && request != null) {
        exchange = await driver.readExchange(request);
      }

      final invalid = file.verify.invalidCredentialOn;
      final invalidVisible = invalid != null &&
          route == invalid.route &&
          await driver.hasElement(invalid.element);

      final elementPresent =
          !loginUiMissing && await driver.hasElement(file.verify.element);

      final failure = classifyAuthSetup(
        file: file,
        seen: AuthObservations(
          route: route,
          routeHistory: driver.routeHistory(),
          loginPerformed: loginPerformed,
          elementPresent: elementPresent,
          request: exchange,
          invalidCredentialVisible: invalidVisible,
          loginUiMissing: loginUiMissing,
          missingElementId: missingElementId,
          handshakeAppId: identity.appId,
        ),
      );

      return _result(
        failure: failure,
        detail: _detailFor(failure, route, missingElementId),
        route: route,
        loginPerformed: loginPerformed,
        elementVerified: elementPresent,
        request: exchange,
        watch: watch,
        identity: identity,
        used: used,
      );
    } on MissingSecretException catch (error) {
      // Raised by the presence check before anything was driven.
      log('  ✗ ${error.ref} is not set');
      return _result(
        failure: AuthSetupFailure.secretMissing,
        detail: '${error.ref} resolved to nothing',
        route: null,
        loginPerformed: false,
        elementVerified: false,
        watch: watch,
        identity: null,
        used: used,
      );
    } finally {
      // Always, and never raising over whatever caused it.
      try {
        await driver.dispose();
      } catch (error) {
        log('  ! could not dispose the session: $error');
      }
    }
  }

  /// The route the first `expectScreen` of [steps] names, or null.
  String? _firstExpectedRoute(List<Step> steps) {
    for (final step in steps) {
      if (step is ExpectScreenStep) return step.screenId;
    }
    return null;
  }

  /// Runs a block, resolving each credential immediately before it is
  /// typed and holding none of them afterwards.
  Future<void> _drive(List<Step> steps, List<SecretRef> used) async {
    for (final step in steps) {
      log('  › ${step.describe()}');
      switch (step) {
        case SecretInputStep(:final elementId, :final ref):
          // Resolved here and nowhere earlier. Nothing retains the
          // Secret once this call returns.
          await driver.inputSecret(elementId, secrets.resolve(ref));
          if (!used.contains(ref)) used.add(ref);
        case TapStep(:final elementId):
          await driver.tap(elementId);
        case ExpectScreenStep(:final screenId, :final timeout):
          await driver.awaitRoute(screenId, timeout);
        case WaitForSettleStep(:final timeout):
          await driver.waitForSettle(timeout);
        case ExpectElementStep(:final elementId):
          if (!await driver.hasElement(elementId)) {
            throw ElementNotFoundException(
              testId: elementId,
              available: const [],
            );
          }
        case LaunchAppStep():
        case BackStep():
        case InputStep():
        case ScreenshotStep():
        case ExpectApiStep():
        case ValidateScreenStep():
          // AuthFile.parse admits only the steps handled above, and
          // refuses the rest by name. Reaching here would mean the
          // parser and this switch had drifted.
          throw StateError(
            '"${step.describe()}" is not a step an auth flow may run',
          );
      }
    }
  }

  /// Checks every declared secret is *there*, without reading any of
  /// them.
  ///
  /// Called before anything is launched, so a typo in a variable name
  /// costs a second rather than a build.
  void requireSecrets() {
    for (final ref in file.declaredSecrets) {
      if (!secrets.isPresent(ref)) throw MissingSecretException(ref);
    }
  }

  String _detailFor(
    AuthSetupFailure? failure,
    String? route,
    String? missingElementId,
  ) =>
      switch (failure) {
        null => '',
        AuthSetupFailure.loginUiNotFound =>
          'the login UI does not carry "$missingElementId"',
        AuthSetupFailure.authenticatedStateNotReached =>
          'the application ended on "$route" rather than '
              '"${file.verify.route}"',
        AuthSetupFailure.authPathNotSupported =>
          'the application went to "$route", which needs a one-time code',
        AuthSetupFailure.invalidCredential =>
          'the application rejected the credential and stayed on "$route"',
        AuthSetupFailure.authRequestFailed =>
          'the authentication request did not answer as declared',
        _ => '',
      };

  AuthSetupResult _result({
    required AuthSetupFailure? failure,
    required String detail,
    required String? route,
    required bool loginPerformed,
    required bool elementVerified,
    required Stopwatch watch,
    required ({String appId, String? version, String? buildMode})? identity,
    required List<SecretRef> used,
    ApiExpectationOutcome? request,
  }) =>
      AuthSetupResult(
        outcome: failure == null
            ? AuthSetupOutcome.succeeded
            : AuthSetupOutcome.failed,
        failure: failure,
        detail: detail,
        remedy: failure?.remedy ?? '',
        route: route,
        routeHistory: driver.routeHistory(),
        loginPerformed: loginPerformed,
        elementVerified: elementVerified,
        request: request,
        durationMs: watch.elapsedMilliseconds,
        secretsUsed: used,
        appId: identity?.appId,
        appVersion: identity?.version,
        buildMode: identity?.buildMode,
        deviceModel: deviceModel,
      );
}
```

**Note for the implementer:** the test calls `AuthRunner(...).run()` and expects the missing-secret path to be reached without an explicit `requireSecrets()` call. Make `run()` call `requireSecrets()` as its very first statement inside the `try`, before `driver.identity()`. Check `ElementNotFoundException`'s constructor in `packages/flutter_testsmith_engine/lib/src/inspection/element_locator.dart` and use its real signature and field names.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_runner_test.dart`
Expected: PASS, 16 tests.

- [ ] **Step 5: Verify**

Run: `cd packages/flutter_testsmith_cli && dart test` then from root `dart analyze --fatal-infos`
Expected: green. **Do not commit.**

---

## Task 9: The command, and the real session adapter

**Files:**
- Create: `packages/flutter_testsmith_cli/lib/src/commands/auth_command.dart`
- Modify: `packages/flutter_testsmith_cli/bin/testsmith.dart`
- Test: `packages/flutter_testsmith_cli/test/auth_command_test.dart`

**Interfaces:**
- Consumes: everything above; `AppSession`, `Output`, `resolveSuiteContext`'s helpers `attachedDevices`, `readDeviceFacts`, `isOnPath`, `loadDeviceProfile`, `availableProfiles`, `grantPermissions`.
- Produces: `class AuthCommand extends Command<int>` (name `auth`), `class AuthSetupSubcommand extends Command<int>` (name `setup`), `class SessionAuthDriver implements AuthDriver`.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_testsmith_cli/test/auth_command_test.dart`:

```dart
// The CI contract for `testsmith auth setup`, driven through the real
// executable, because an exit code is not something a library call has.
//
// 0 authenticated, 2 the run is wrong, 64 the invocation is wrong. Never
// 1: auth setup judges no screen, so it is never in a position to say
// the application is wrong.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _mytest(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/testsmith.dart', ...arguments],
      workingDirectory: Directory.current.path,
    );

late Directory _root;

void _write(String path, String contents) {
  File('${_root.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}

const String _authFile = '''
auth: t
app: {path: ., target: lib/main_uat.dart, flavor: f}
appId: com.example.app
device: {profile: p}
secrets: {pin: env:MYTEST_AUTH_PIN}
signedOutOn: [/login]
login:
  - tap: {id: continue_button}
verify: {route: /home, element: home.body}
''';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('auth_cmd');
    addTearDown(() => _root.deleteSync(recursive: true));

    _write('proj/device_profiles/p.yaml', 'id: p\n');
    _write('proj/lib/main_uat.dart', 'void main() {}');
    _write('proj/mytest/auth/uat.yaml', _authFile);
  });

  test('the command is registered', () async {
    final result = await _mytest(['--help']);
    expect(result.stdout.toString(), contains('auth'));
  });

  test('no argument is 64', () async {
    expect((await _mytest(['auth', 'setup'])).exitCode, 64);
  });

  test('more than one argument is 64', () async {
    expect((await _mytest(['auth', 'setup', 'a.yaml', 'b.yaml'])).exitCode, 64);
  });

  test('no such auth file is 2', () async {
    final result = await _mytest(['auth', 'setup', '${_root.path}/nope.yaml']);
    expect(result.exitCode, 2);
    expect(result.stdout.toString(), contains('No such auth file'));
  });

  test('a malformed auth file is 2 and says what is wrong', () async {
    _write('proj/mytest/auth/bad.yaml', 'auth: t\nbypass: true\n');
    final result =
        await _mytest(['auth', 'setup', '${_root.path}/proj/mytest/auth/bad.yaml']);
    expect(result.exitCode, 2);
    expect(result.stdout.toString(), contains('bypass'));
  });

  test('a missing secret is 2, and nothing is built', () async {
    // MYTEST_AUTH_PIN is not set in this process, so the presence check
    // refuses before any device is touched.
    final result = await _mytest([
      'auth',
      'setup',
      '${_root.path}/proj/mytest/auth/uat.yaml',
      '-d',
      'NO_SUCH_DEVICE',
    ]);
    expect(result.exitCode, 2);
    final output = result.stdout.toString();
    expect(output, contains('MYTEST_AUTH_PIN'));
    expect(output, isNot(contains('Building')));
  });

  test('the usage line names the file, not a suite', () async {
    final result = await _mytest(['auth', 'setup', '--help']);
    expect(result.stdout.toString(), contains('auth setup <auth.yaml>'));
  });

  test('no output ever prints a secret value', () async {
    final result = await _mytest([
      'auth',
      'setup',
      '${_root.path}/proj/mytest/auth/uat.yaml',
      '-d',
      'NO_SUCH_DEVICE',
    ]);
    final text = '${result.stdout}${result.stderr}';
    expect(text, isNot(contains('SEEDED')));
    expect(text, contains('env:MYTEST_AUTH_PIN'));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_command_test.dart`
Expected: FAIL — `auth` is not a known command.

- [ ] **Step 3: Write the command and the adapter**

Create `packages/flutter_testsmith_cli/lib/src/commands/auth_command.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_testsmith_engine/flutter_testsmith_engine.dart';

import '../app_session.dart';
import '../auth_preflight.dart';
import '../auth_runner.dart';
import '../dotenv.dart';
import '../env_secret_resolver.dart';
import '../output.dart';
import '../project_config.dart';
import '../suite_runner.dart';
import 'preflight_command.dart';

/// Adapts a launched application onto what [AuthRunner] needs.
///
/// Thin on purpose: every decision lives in [AuthRunner], which is
/// unit-tested against a scripted driver, and everything here is wiring
/// that only a handset can exercise.
class SessionAuthDriver implements AuthDriver {
  SessionAuthDriver(this.session);

  final AppSession session;

  @override
  Future<String?> currentRoute() async => session.manager.currentScreenId;

  @override
  List<String> routeHistory() => session.manager.screenHistory;

  @override
  Future<void> tap(String elementId) => session.tapById(elementId);

  @override
  Future<void> inputSecret(String elementId, Secret secret) async {
    await session.tapById(elementId);
    // The only call site of `inputSecret` in the platform. The value
    // reaches the device and nothing else: the command string the
    // exception would render is the marker.
    await session.device.inputSecret(secret);
  }

  @override
  Future<void> waitForSettle(Duration timeout) async {
    await session.waitForSettle(timeout: timeout);
  }

  @override
  Future<void> awaitRoute(String route, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (session.manager.currentScreenId == route) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Future<bool> hasElement(String elementId) async {
    try {
      return ElementLocator(await session.captureUiTree()).contains(elementId);
    } on Object {
      return false;
    }
  }

  @override
  Future<ApiExpectationOutcome?> readExchange(ExpectApiStep step) async {
    const evaluator = ApiExpectationEvaluator();
    final deadline = DateTime.now().add(step.timeout);

    var outcome = evaluator.evaluate(
      step: step,
      history: session.correlate().sessions,
    );
    while (!outcome.satisfied && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      outcome = evaluator.evaluate(
        step: step,
        history: session.correlate().sessions,
      );
    }
    return outcome;
  }

  @override
  Future<({String appId, String? version, String? buildMode})> identity() async {
    final app = session.handshake.app;
    return (
      appId: app.appId,
      version: app.appVersion,
      buildMode: app.buildMode,
    );
  }

  @override
  Future<void> dispose() => session.dispose();
}

/// `testsmith auth` - establish an authenticated application state.
class AuthCommand extends Command<int> {
  AuthCommand() {
    addSubcommand(AuthSetupSubcommand());
  }

  @override
  String get name => 'auth';

  @override
  String get description =>
      'Establish an authenticated application state through the real login UI.';
}

class AuthSetupSubcommand extends Command<int> {
  AuthSetupSubcommand() {
    argParser
      ..addOption('device', abbr: 'd', help: 'Device serial.')
      ..addOption('out', help: 'Where to write auth.json.');
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Sign in on the device by driving the real login UI, and verify it.';

  @override
  String get invocation => 'testsmith auth setup <auth.yaml>';

  static const int _usage = 64;
  static const int _error = 2;

  @override
  Future<int> run() async {
    final output = Output();
    final args = argResults!;

    if (args.rest.length != 1) {
      output
        ..line(output.red('Expected exactly one auth file.'))
        ..line(output.dim('Usage: $invocation'));
      return _usage;
    }

    final authFile = File(args.rest.single);
    if (!authFile.existsSync()) {
      output.line(output.red('No such auth file: ${authFile.path}'));
      return _error;
    }

    final AuthFile file;
    try {
      file = AuthFile.parse(await authFile.readAsString(), source: authFile.path);
    } on AuthFormatException catch (error) {
      output.line(output.red('$error'));
      return _error;
    } on SecretRefFormatException catch (error) {
      output.line(output.red('$error'));
      return _error;
    }

    final project = Directory('${authFile.parent.path}/${file.app.path}');

    // 1a. Every secret is *there*, before anything is built. A bool, and
    // never the value: a presence check must not pull a credential into
    // the process.
    final resolver = EnvSecretResolver(
      dotenv: DotEnv.load([project.path, Directory.current.path]),
    );
    final missing = [
      for (final ref in file.declaredSecrets)
        if (!resolver.isPresent(ref)) ref,
    ];
    if (missing.isNotEmpty) {
      output
        ..line(output.red('Missing credential${missing.length == 1 ? '' : 's'}:'))
        ..line(output.dim(
          [for (final ref in missing) '  $ref is not set'].join('\n'),
        ))
        ..line(output.dim(
          '  Set them in the environment, or in a .env file that is not '
          'committed. The value is never read until the moment it is typed.',
        ));
      return _error;
    }

    // 1b. The device profile, and a device.
    final profile = await loadDeviceProfile(project, file.deviceProfile);
    if (profile == null) {
      final available = availableProfiles(project);
      output
        ..line(output.red('No device profile "${file.deviceProfile}".'))
        ..line(output.dim(
          '  Looked in ${project.path}/device_profiles. Available: '
          '${available.isEmpty ? '(none)' : available.join(', ')}',
        ));
      return _error;
    }

    final attached = await attachedDevices();
    final serial = args.option('device') ??
        (attached.length == 1 ? attached.single.serial : null);
    if (serial == null) {
      output.line(output.red(
        attached.isEmpty
            ? 'No usable device attached. Run: testsmith devices'
            : 'Several devices attached; choose one with --device.',
      ));
      return _error;
    }
    final facts = await readDeviceFacts(serial, attached);

    // 2. Arrange, then verify - E-04's ordering, and gated on the device
    // being the profile's, so no unrelated handset is modified.
    final device = AdbDeviceController(serial: serial);
    final deviceOk = checkDeviceAttached(attached: attached, requested: serial);
    final profileOk = checkProfileMatch(profile: profile, facts: facts);
    if (file.devicePermissions.isNotEmpty &&
        !deviceOk.isBlocking &&
        !profileOk.isBlocking) {
      await grantPermissions(
        appId: file.appId,
        permissions: file.devicePermissions,
        device: device,
        log: output.line,
      );
    }

    // 3. Preflight.
    final preflight = await AuthPreflightRunner(
      file: file,
      projectDirectory: project,
      profile: profile,
      deviceEnvironment: AdbDeviceEnvironment(serial: serial),
      attachedDevices: attached,
      requestedSerial: serial,
      deviceFacts: facts,
      flutterOnPath: await isOnPath('flutter'),
    ).run();
    output.renderPreflight(preflight);

    if (preflight.isBlocked) {
      await _write(
        args.option('out'),
        AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: AuthSetupFailure.environmentPrerequisite,
          detail: preflight.blockers.map((c) => c.name).join(', '),
          remedy: AuthSetupFailure.environmentPrerequisite.remedy,
          loginPerformed: false,
          secretsUsed: file.declaredSecrets,
          deviceModel: facts.model,
        ),
        output,
      );
      return _error;
    }

    // 4. Launch the declared build. No reverse port and no fixture
    // server: this build talks to the real backend.
    final AppSession session;
    try {
      session = await AppSession.launch(
        projectDirectory: project,
        deviceSerial: serial,
        appId: file.appId,
        log: output.line,
        target: file.app.target,
        flavor: file.app.flavor,
        dartDefines: file.app.dartDefines,
      );
    } catch (error) {
      output.line(output.red('Could not launch the application: $error'));
      await _write(
        args.option('out'),
        AuthSetupResult(
          outcome: AuthSetupOutcome.failed,
          failure: AuthSetupFailure.environmentPrerequisite,
          detail: 'the application did not start',
          remedy: AuthSetupFailure.environmentPrerequisite.remedy,
          loginPerformed: false,
          secretsUsed: file.declaredSecrets,
          deviceModel: facts.model,
        ),
        output,
      );
      return _error;
    }

    // 5-7. Observe, verify, tear down.
    final result = await AuthRunner(
      file: file,
      secrets: resolver,
      driver: SessionAuthDriver(session),
      log: output.line,
      deviceModel: facts.model,
    ).run();

    _render(result, output);
    await _write(args.option('out'), result, output);
    return result.exitCode;
  }

  void _render(AuthSetupResult result, Output output) {
    output.line();
    if (result.succeeded) {
      output.line(output.green(
        result.loginPerformed
            ? 'AUTHENTICATED  signed in through the real login UI, and '
                'reached "${result.route}"'
            : 'AUTHENTICATED  already signed in; "${result.route}" verified '
                'without using a credential',
      ));
      return;
    }
    output
      ..line(output.red('NOT AUTHENTICATED  ${result.failure!.wire}'))
      ..line(output.dim('  ${result.detail}'))
      ..line(output.dim('  -> ${result.remedy}'));
  }

  Future<void> _write(
    String? directory,
    AuthSetupResult result,
    Output output,
  ) async {
    if (directory == null) return;
    final file = File('$directory/auth.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result.toJson()),
    );
    output.line(output.dim('  wrote ${file.path}'));
  }
}
```

**Note for the implementer:** `session.handshake.app` field names (`appId`, `appVersion`, `buildMode`) come from `AppContext` in `packages/flutter_testsmith_protocol/lib/src/app_context.dart`. Read that file and use the real names. `AdbDeviceEnvironment` is in `packages/flutter_testsmith_cli/lib/src/adb_device_environment.dart`.

- [ ] **Step 4: Register the command**

In `packages/flutter_testsmith_cli/bin/testsmith.dart`, add the import:

```dart
import 'package:flutter_testsmith_cli/src/commands/auth_command.dart';
```

and add to the runner chain, keeping alphabetical order — before `..addCommand(DoctorCommand())`:

```dart
    ..addCommand(AuthCommand())
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_testsmith_cli && dart test test/auth_command_test.dart`
Expected: PASS, 8 tests.

- [ ] **Step 6: Verify everything**

Run:
```
cd packages/flutter_testsmith_protocol && dart test
cd ../flutter_testsmith_engine && dart test
cd ../flutter_testsmith_cli && dart test
cd ../.. && dart analyze --fatal-infos && dart run scripts/check_dependencies.dart
```
Expected: all green, no analyzer issues, and **E-04's suite and preflight tests unchanged**. **Do not commit.**

---

## Task 10: The application side

**Files (in `D:\Repositories\external_app`):**
- Modify: `lib/features/auth/presentation/screens/secure_login_screen.dart`
- Create: `mytest/auth/uat.yaml`
- Modify: `mytest/suites/regression.yaml`

- [ ] **Step 1: Add the three test ids**

In `_SecureLoginCard.build`, wrap the PIN field, the continue button, and the error text. The `TestId` widget is already imported throughout this codebase — check how `login_screen.dart` imports it and match.

Replace the `AppTextField(...)` that takes `controller: controller` with:

```dart
            TestId(
              id: 'secure_login.pin_field',
              child: AppTextField(
                controller: controller,
                hintText: AppStrings.enterLoginPin,
                keyboardType: TextInputType.number,
                obscureText: !isPinVisible,
                autoUnfocusLength: 6,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                suffix: _PinVisibilityButton(
                  isVisible: isPinVisible,
                  onTap: onTogglePinVisibility,
                ),
                hasError: pinErrorMessage != null,
              ),
            ),
```

Replace the error branch with:

```dart
            if (pinErrorMessage != null) ...[
              const AppSizedBox.designHeight(8),
              TestId(
                id: 'secure_login.pin_error',
                child: _PinErrorText(message: pinErrorMessage!),
              ),
              const AppSizedBox.designHeight(16),
            ] else
              const AppSizedBox.designHeight(20),
```

Replace the PIN continue button — the first `AppButton` after the error branch, the one whose `onPressed` is `onPinContinue` — with:

```dart
            TestId(
              id: 'secure_login.continue_button',
              child: AppButton(
                label: isPinLoginLoading
                    ? AppStrings.loggingIn
                    : AppStrings.continueText,
                onPressed:
                    isContinueEnabled &&
                        !isPinLoginLoading &&
                        !isOtpRequestLoading
                    ? onPinContinue
                    : null,
              ),
            ),
```

**Do not wrap the "Continue with OTP" button.** Giving it an id would make an unsupported path tappable from a flow.

**The PIN field keeps `obscureText`.** That is what makes the SDK render it as `[REDACTED:n]` in the UI tree. Nothing may tap `_PinVisibilityButton`, and nothing gives it a test id.

- [ ] **Step 2: Verify the application still builds and its tests pass**

Run: `cd /d/Repositories/external_app && flutter analyze && flutter test`
Expected: unchanged. These are wrapper-only changes with no behaviour change.

- [ ] **Step 3: Write the auth file**

Create `D:\Repositories\external_app\testsmith\auth\uat.yaml` with the full content from the spec's §6, including its comments. Verify the two test ids on `/login` against the application: `login.mobile_field` and `login.continue_button` are at `login_screen.dart:470` and `:485`, and `onboarding.get_started` is what `mytest/tests/login.yaml` already taps.

- [ ] **Step 4: Point the suite's remedy at the command**

In `mytest/suites/regression.yaml`, replace the `authenticated` precondition's `remedy:` with:

```yaml
    remedy: >
      Run `testsmith auth setup mytest/auth/uat.yaml -d <serial>`. It drives
      the application's own login UI on the UAT build, with credentials
      taken from environment-backed secret references, and verifies that
      the personalised dashboard was reached. It never writes application
      state to fake a session.
```

Text only. No behaviour changes, and the suite's parsing is unaffected.

- [ ] **Step 5: Verify the auth file parses**

Run from the platform repo:
```
cd /d/Repositories/flutter-ai-test-platform
dart run packages/flutter_testsmith_cli/bin/testsmith.dart auth setup /d/Repositories/external_app/mytest/auth/uat.yaml -d NO_SUCH_DEVICE
```
Expected: exit 2, with either a missing-credential message naming `env:MYTEST_AUTH_MOBILE`/`env:MYTEST_AUTH_PIN`, or a device message — **not** a parse error. **Do not commit.**

---

## Task 11: Real hardware acceptance

Not a TDD task. This is the gate the brief's §10 defines, and every command's output must be captured for the evidence section.

**Preconditions:** the Samsung SM-M127G attached, USB debugging on, **location service on** (§11 case F), and `MYTEST_AUTH_MOBILE` / `MYTEST_AUTH_PIN` exported in the shell — never written to a file in either repository.

- [ ] **Step 1: Sign the device out, so RUN 1 starts from a signed-out state**

```
adb -s <serial> shell pm clear com.example.testapp.alpha
```

Record that this was done and why: `login`'s own `clearState` produces the same state, so this is the state E-04's suite already leaves behind.

- [ ] **Step 2: RUN 1 — a real login**

```
cd /d/Repositories/external_app
testsmith auth setup mytest/auth/uat.yaml -d <serial> --out ../flutter-ai-test-platform/out/e05-run1
```
Expected: exit **0**, `AUTHENTICATED  signed in through the real login UI`, `loginPerformed: true`, `route: /home`.
Capture the full stdout and `out/e05-run1/auth.json`.

- [ ] **Step 3: RUN 2 — already authenticated**

Without signing out:

```
testsmith auth setup mytest/auth/uat.yaml -d <serial> --out ../flutter-ai-test-platform/out/e05-run2
```
Expected: exit **0**, `already signed in`, `loginPerformed: false`, `secretsUsed: []`.

- [ ] **Step 4: The E-04 suite on the state RUN 1 established**

```
testsmith suite run mytest/suites/regression.yaml -d <serial> \
  --out ../flutter-ai-test-platform/out/e05-suite
```
Expected exactly: `home` PASS, `orders` PASS, `profile` PASS, `journey` PASS, `login` FAIL with 8 findings; `counts {pass: 4, fail: 1, error: 0, skip: 0}`; exit **1**.

- [ ] **Step 5: Prove the eight Login findings are field-for-field identical**

Compare `out/e05-suite/login/result.json` against E-04's accepted `out/e04-accept/login/result.json` on validator, element and message for all eight. Any difference is a blocker, not a note.

- [ ] **Step 6: The leakage audit**

Search every artefact all three runs produced for the two real credential values:

```
grep -ri "$MYTEST_AUTH_PIN" out/e05-run1 out/e05-run2 out/e05-suite
grep -ri "$MYTEST_AUTH_MOBILE" out/e05-run1 out/e05-run2 out/e05-suite
```
Expected: **no matches**, in `auth.json`, `suite.json`, every `result.json`, every `report.html`, and every `.png`. Also confirm no device serial appears in `auth.json`, and that `git status` in both repositories shows no new untracked file containing a credential.

- [ ] **Step 7: Confirm no unrelated state was left behind**

```
adb -s <serial> reverse --list        # expect empty
git status visual_baselines/          # expect empty
```

- [ ] **Step 8: Regression, in full**

```
cd /d/Repositories/flutter-ai-test-platform
dart analyze --fatal-infos
dart run scripts/check_dependencies.dart
(cd packages/flutter_testsmith_protocol && dart test)
(cd packages/flutter_testsmith_engine && dart test)
(cd packages/flutter_testsmith_cli && dart test)
(cd packages/flutter_testsmith && flutter test)
(cd examples/ecommerce_app && flutter test)
cd /d/Repositories/external_app && flutter analyze && flutter test
```
Expected: all green. **Do not commit.**

---

## Task 12: The documentation

**Files:**
- Create: `docs/E-05_AUTHENTICATION_SETUP.md`

- [ ] **Step 1: Write it**

Match the voice and structure of `docs/E-04_TEST_ENVIRONMENT.md`. Required sections, from the brief's §12:

1. architecture, and why a separate command rather than a suite phase (spec §3)
2. CLI usage, with the real invocations from Task 11
3. secret-reference format (spec §4)
4. the security boundary, including the three leaks found and fixed (spec §5)
5. the no-bypass rule, with the establish/verify distinction and the forbidden list (spec §2)
6. lifecycle (spec §7)
7. device and build selection, answering all eight of the brief's questions (spec §10)
8. success verification (spec §8)
9. failure classification and the precedence (spec §9, §9.0)
10. repeatability (spec §11)
11. **real-device evidence** — the captured output from Task 11, including both runs, the suite, and the leakage audit
12. known limitations (spec §15)

Every claim in section 11 must be something Task 11 actually produced. A claim must not exceed its evidence: where a run was not performed, say so rather than describing what it would have shown.

- [ ] **Step 2: Cross-check E-04**

Update `docs/E-04_TEST_ENVIRONMENT.md` §14 limitation 1 to point at E-05 — a one-line change saying the limitation is now closed and where. Do not rewrite anything else in E-04.

- [ ] **Step 3: Verify**

Re-read both documents against the actual artefacts. **Do not commit — present the gate package instead.**

---

## The gate package

After Task 12, present to the user, in this order, and **wait**:

1. architecture/design decision — spec §2, §3, §4
2. exact files changed — `git status` in both repositories
3. security model — spec §2, §4, §5, §9.1
4. test results — the full output from Task 11 step 8
5. real-device evidence — Task 11 steps 2–7
6. exact CLI usage
7. leakage audit — Task 11 step 6
8. final acceptance matrix against the brief's fourteen sections

Then wait for gate approval before any commit. Never push.
