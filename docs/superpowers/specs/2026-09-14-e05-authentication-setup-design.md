# E-05 — Authentication setup: design

Establishing a real session through the real login UI, without ever
becoming the thing it establishes.

Status: design, approved 2026-09-14. Not yet implemented.

---

## 1. What E-04 left open

E-04 closed the reporting half of the authentication problem and said so
plainly: a signed-out device now reports PRECONDITION per test instead of
four product failures blaming four screens. What it did not close is the
prerequisite itself, recorded as its first known limitation:

> **The suite still cannot sign itself in.** The sign-in itself is still a
> sequence of `adb` taps against the real UI.

E-04 also recorded why it did not simply automate it, and E-05 inherits
every one of those reasons rather than reopening them:

- a fixture login would accept any PIN, because scenario routes match on
  method and path only. That is an authentication bypass wearing a test
  fixture's clothes.
- the flow DSL's `InputStep.describe()` renders `type "<value>" into
  "<elementId>"`, which would put a credential in `result.json`, in
  `report.html` and on the console.
- a suite `setup:` phase cannot express it, because setup must run a
  *different build* from the tests.

E-05 is the shape E-04 recommended, built now that there is evidence for
it.

---

## 2. The boundary this whole milestone rests on

> **Establish** — the application's own code ran and changed its own state.
> **Verify** — the runner read something the application chose to show.

Auth setup only ever taps and types into the real UI. Everything it uses
as evidence is a decision the application made for its own reasons:

| signal | who decided it | why it is evidence |
|---|---|---|
| the route the router chose on a cold start | `splash_screen.dart` | `isLoggedIn == false` goes to `/onboarding` or `/login`; only `true` reaches the landing route |
| `home.body` present in the tree | the widget tree | the dashboard rendered, not merely that a route event fired |
| `POST /login/consumer` answered 200 | the application's own HTTP client | the real authentication request, read from the SDK's capture |

Inspection may confirm authentication. Inspection may never create it.

**Forbidden, and none of it appears anywhere in the design:**
SharedPreferences mutation, local database mutation, secure-storage
mutation, token injection, auth-header injection, direct API login,
fixture login, fake auth endpoint, `run-as` state mutation, modifying app
files or state to appear authenticated, setting an internal authenticated
boolean, bypassing onboarding or login routes.

`DeviceEnvironment` gains nothing in E-05. It still reads no application
storage, and E-04's redaction test — which asserts that no artefact so
much as *names* `is_logged_in`, `SharedPreferences`, `run-as` or a token —
still holds, because the route not taken must not be signposted.

### 2.1 Why cold start is load-bearing

`/home` is guest-browsable. `_isGuestBrowsable` in `app_router.dart`
admits `/home`, `/home/business-list` and `/business/...`, so a guest who
tapped Skip can navigate to `/home` without a session.

What a guest cannot do is *start* there. On a cold launch the splash
reads `isLoggedIn`, and a false value goes to `/onboarding` or `/login`
before anything else can happen.

So the proposition E-05 verifies is not "the app is on `/home`". It is:

> a cold start reached `/home` without passing through `/login` or
> `/onboarding`

which is checked against `SessionManager.screenHistory`, not only against
`currentScreenId`. A run that reached `/home` by any other path is not
accepted as evidence of a session.

---

## 3. Why a separate command rather than a suite phase

E-04 rejected a suite `setup:` phase for a structural reason. Read off
the two entry points, that reason is not incidental:

| | auth setup | the suite under test |
|---|---|---|
| entry point | `lib/main_example.dart` | `lib/main_mytest.dart` |
| env asset | `.env.uat` | `.env.mytest` |
| API base | the real UAT backend | `http://127.0.0.1:8080` |
| `adb reverse` | none | `tcp:8080` |
| fixture server | must not run | runs, once per suite |
| external service | **required** | forbidden |
| lifecycle | once per device; outlives many suites | once per suite |

A suite's single `app:` block cannot express two builds, and making it
able to would make a suite file two suites.

What makes a separate command work at all is that both entry points
compile the same flavor, so both install as
`com.example.testapp.alpha`. An upgrade install with the same
signing key preserves application data, which is exactly why E-04's
manual sign-in on the UAT build survives the suite's launch of the testsmith
build. E-05 automates that sequence; it does not invent it.

**Decision: `testsmith auth setup <auth.yaml> -d <serial>`** — its own
command, its own file, its own lifecycle.

---

## 4. Secret reference and secret value

The architecture separates the two as types, so that confusing them is a
compile error rather than a review comment.

`flutter_testsmith_engine/lib/src/auth/secret_ref.dart`:

- **`SecretRef`** — a scheme and a name, parsed from `env:MYTEST_AUTH_PIN`.
  This is what YAML carries, what `describe()` renders, and what a report
  records. `toString()` returns the reference.
- **`Secret`** — a resolved value. **`toString()` returns `[REDACTED]`**,
  reusing `RedactionPolicy.marker`. Accidental interpolation anywhere in
  the codebase therefore yields the marker rather than the credential —
  the failure mode is safe by construction rather than by vigilance.
  `expose()` is the only way to the string, and is called at exactly one
  site.
- **`SecretResolver`** — an interface. `EnvSecretResolver` reads
  `Platform.environment` first and the existing `DotEnv` second, which is
  the precedence `DotEnv` already documents: the real environment always
  wins, so CI is never overridden by a developer's local file.
- **`MissingSecretException`** — names the reference, never a value, and
  never the surrounding state.

### 4.0 Presence is checked early; the value is read late

There is a real tension between two requirements, and the design resolves
it rather than picking a side:

- a missing secret must stop the run **before** anything is built or
  launched (§7 step 1), otherwise the command spends two minutes
  compiling in order to report a typo in a variable name;
- the value must be in memory **only** for the interaction that needs it.

So step 1 asks the resolver a different question from the one the input
step asks. `SecretResolver.isPresent(SecretRef)` answers whether a
non-empty value exists, and returns a `bool` — it never returns, stores
or logs the value. `SecretResolver.resolve(SecretRef)` returns a `Secret`
and is called once, immediately before the `inputSecret` step that needs
it. Nothing holds a `Secret` across steps, and nothing holds one after
the session is disposed.

`env:` is the only scheme in E-05. It is the smallest secure
implementation, and the seam is the `SecretResolver` interface, so a file
or keychain provider is a new implementation rather than a new design.

### 4.1 The step

`SecretInputStep` is declared in `dsl/steps.dart`, because `Step` is
`sealed` and Dart permits subclasses only in the declaring library. That
is a benefit rather than a nuisance: `FlowExecutor`'s switch is checked
for exhaustiveness, so the new step forces an explicit decision at the
one place that runs product flows.

```dart
String describe() => 'type <$ref> into "$elementId"';
// -> type <env:MYTEST_AUTH_PIN> into "secure_login.pin_field"
```

`FlowExecutor` gets a rejecting case: a secret step inside a product flow
throws, naming the invariant. It cannot arrive there through the parser
either (§6.1), so the case is a second lock on a door that is already
shut.

---

## 5. The three leaks found, and their fixes

Each was found by reading the code during design, and each is fixed in
E-05 because §2 of the brief requires it before completion.

### 5.1 `DeviceCommandException` renders the whole command

`device_controller.dart:50` builds its message from the full command
string, and that string is built in `adb_device_controller.dart:31` from
the full argument vector. `inputText` passes the typed value as an
argument. A failed `adb shell input text <PIN>` therefore puts the PIN
into the exception message, which `FlowExecutor` copies into
`StepOutcome.detail`, which reaches `result.json`, `report.html` and
stdout.

**Fix.** `_adb` gains an optional display form. A new
`DeviceController.inputSecret(Secret)` sends the real value to the
process and the redaction marker to the exception. The existing
`inputText` is untouched, so no E-04 behaviour changes.

### 5.2 `InputStep.describe()` renders the value

Named by E-04 as the reason the flow DSL must not be used for a
credential. `SecretInputStep` is the answer (§4.1).

### 5.3 The mobile number is not obscured

The PIN is safe already: the SDK masks obscured fields to
`[REDACTED:n]` (`ui_tree_inspector.dart:359`), and the PIN field is
`obscureText: !isPinVisible`. The mobile number is not:

- plaintext in the UI tree from `login.mobile_field`;
- rendered again as RichText in `_SecureLoginSubtitle` on `/secure-login`;
- visible in any screenshot of either screen;
- in the query of `GET /isconsumerexist?mobilenumber=...`;
- in the body of `POST /login/consumer` as `mobileNumber`, which
  `RedactionPolicy` does not match — `pin` is an exact sensitive key, and
  `mobilenumber` matches neither the key list nor any pattern.

**Fix.** Auth setup writes **no screenshot and no UI tree into any
artefact**. It is not a test and makes no claim about a screen, so it has
no reason to photograph one. The only tree read is in memory, to resolve
a tap target and to answer one presence question.

**Deliberately not fixed here: the global redaction policy.** Adding
`mobileNumber` to `RedactionPolicy` would change what E-04's existing
`profile` artefacts contain — `mappings/profile.yaml:56` reads
`data.mobileNumber` — and §11 of the brief requires proving no E-04
behaviour was weakened. Auth setup solves its own exposure by writing no
bodies at all. The observation is carried into §15 as a limitation and a
follow-up for whoever owns the SDK's defaults.

The toggle that would defeat the PIN masking — `_PinVisibilityButton`,
which sets `isPinVisible` — is never tapped, and the auth flow parser
cannot express a step that would.

---

## 6. The auth file

`mytest/auth/uat.yaml`, in the application repository, beside
`mytest/suites/` and `mytest/tests/`.

```yaml
auth: test

app:
  path: ../..
  target: lib/main_example.dart
  flavor: example

# Asserted against the handshake, so the runner proves which application
# it is driving rather than assuming the one it asked for is the one that
# answered.
appId: com.example.testapp.alpha

device:
  profile: samsung-m127g
  permissions:
    - android.permission.ACCESS_FINE_LOCATION
    - android.permission.ACCESS_COARSE_LOCATION

secrets:
  mobile: env:MYTEST_AUTH_MOBILE
  pin: env:MYTEST_AUTH_PIN

# Where this application's own router sends an unmet session. Declared by
# a person, exactly as E-04's `unmetOn` is, and for the same reason: only
# a person knows that *this* application shows these routes when it holds
# no session.
signedOutOn: [/onboarding, /login]

# Entered only when the launch landed on /onboarding.
onboarding:
  - expectScreen: {id: /onboarding, timeoutMs: 40000}
  - waitForSettle: {timeoutMs: 30000}
  - tap: {id: onboarding.get_started}

login:
  - expectScreen: {id: /login, timeoutMs: 40000}
  - waitForSettle: {timeoutMs: 30000}
  - inputSecret: {id: login.mobile_field, secret: mobile}
  - tap: {id: login.continue_button}
  - expectScreen: {id: /secure-login, timeoutMs: 40000}
  - waitForSettle: {timeoutMs: 30000}
  - inputSecret: {id: secure_login.pin_field, secret: pin}
  - tap: {id: secure_login.continue_button}

verify:
  # How long to wait for `route` to arrive after the login block's last
  # step, or after launch on the already-authenticated path. It covers
  # the real authentication request and the location gate behind it.
  route: /home
  timeoutMs: 60000
  element: home.body
  request: {endpoint: POST /login/consumer, status: 200}
  notOn: [/set-location, /otp-verification, /registration-otp, /secure-login]

  # How this application says "that PIN was wrong": it stays on the
  # secure-login route and renders an error under the field. Declared,
  # because the alternative is inferring it from an HTTP status — and
  # this backend's own repository maps a rejected login through
  # `onFailure` rather than necessarily through a non-2xx, so a status
  # rule would be a guess about a convention nobody here controls.
  invalidCredentialOn:
    route: /secure-login
    element: secure_login.pin_error
```

Two blocks rather than a conditional step: after launch the runner reads
the route the application chose and enters at the block that matches. A
DSL with an `if` is a DSL that grows a language; a DSL with two named
entry points is a DSL that grows a second name.

### 6.1 What the parser refuses

Enforced at parse time, with a test each, because a security property
that depends on nobody writing the wrong line is not a security property:

| refused | why |
|---|---|
| `screenshot:` | an auth screen shows an unobscured mobile number |
| `validateScreen:` | it photographs, and it writes trees into a report |
| `input:` | plaintext. Every value must go through a secret reference |
| `expectApi:` inside `login:`/`onboarding:` | assertion belongs in `verify:`, where its shape is constrained |

The step set permitted in an auth flow is therefore:
`expectScreen`, `waitForSettle`, `tap`, `expectElement`, `back`,
`inputSecret`. Every one of these already exists and is already tested;
E-05 adds exactly one new interaction primitive, and it adds it because
the alternative is a credential in a report.

---

## 7. Lifecycle

```
testsmith auth setup <auth.yaml> -d <serial>
  |
  +- 1 RESOLVE ---- auth syntax - device profile - a device to drive
  |                 - every secret reference resolves         [no launch]
  |                 a missing secret stops here, exit 2, nothing launched
  |
  +- 2 ARRANGE ---- grant the permissions the file declares
  |                 (gated on device + profile, E-04's rule, E-04's code)
  |
  +- 3 PREFLIGHT -- application build - device - device profile
  |                 - permissions - network interface
  |                 - UAT backend -> DEFERRED (externalService)
  |                 blocked => exit 2, nothing launched
  |
  +- 4 LAUNCH ----- the UAT build, --dart-define=TEST_MODE=true,
  |                 no adb reverse, no fixture server
  |                 => handshake appId must equal the declared appId
  |
  +- 5 OBSERVE ---- the route the application's own router chose
  |                    /home        -> already authenticated; no login
  |                    /onboarding  -> onboarding block, then login block
  |                    /login       -> login block
  |                    otherwise    -> classified failure
  |
  +- 6 VERIFY ----- route - screenHistory - element - request - notOn
  |
  +- 7 TEARDOWN --- dispose the session — always, in a finally, recorded
                    step by step, failures reported and not raised
```

**Arrange before verify** is E-04's ordering and E-04's reasoning: a file
declares `device.permissions` precisely so the runner will grant them, so
a check that read the device first would refuse a fresh run over a state
the very next step was about to establish. `arrangeDeclaredPermissions`
is reused, not reimplemented.

**Preflight is composed, not inherited.** E-04's preflight is built around
a `SuiteFile`, but its checks — `checkApplicationBuild`,
`checkDeviceAttached`, `checkProfileMatch`, `checkPermissions`,
`checkNetworkInterface` — are already standalone pure functions in
`preflight_checks.dart`. Auth setup composes its own `PreflightReport`
from the same functions. Reuse of the machinery, without pretending an
auth file is a suite.

**The backend check is `deferred`, and is not probed.** E-04 §2 records
that the UAT backend is the one thing only authentication setup ever
addresses. The runner does not reach for it: a probe from the host would
be a network call the platform otherwise never makes, and it would prove
only that the host can reach it. It is recorded as `deferred` with class
`externalService`, and a backend that is not there surfaces as
`AUTH_REQUEST_FAILED` from the application's own attempt — which is the
honest place for it to surface.

**The launch cost is real and is not hidden.** Auth setup builds and
installs the UAT entry point; the suite afterwards builds and installs
the testsmith one. Two full builds per acceptance cycle. Correct, and slow.

---

## 8. Verification

Success is a conjunction. Each term is necessary, and the brief forbids
resting on either of the two weak ones alone.

| term | source | what it rules out |
|---|---|---|
| final route is `verify.route` | `SessionManager.currentScreenId` | landing anywhere else |
| `screenHistory` did not pass `signedOutOn`, when no login was performed | `SessionManager.screenHistory` | a guest navigating to `/home` |
| `verify.element` is present | one in-memory tree read | a route event without a rendered screen |
| `verify.request` answered its status, **when a login was performed** | `ApiExpectationEvaluator` over the app's own capture | a session that was never actually granted |
| the final route is not in `verify.notOn` | `currentScreenId` | `/set-location`, the OTP routes |

`verify.request` is evaluated with the **existing**
`ApiExpectationEvaluator` and an `ExpectApiStep` carrying an endpoint and
a status and **no field expectations**. `ApiExpectationOutcome.toJson()`
serialises `endpoint`, `status`, `screenId`, `durationMs`, `satisfied`
and `failures` — no body, no headers, no URL query. The declared endpoint
is `POST /login/consumer`, which carries no query. `GET /isconsumerexist`
is deliberately **not** asserted on, because its query string carries the
mobile number.

On the already-authenticated path there is no login request to assert, so
that term is skipped rather than failed — and the report records
`loginPerformed: false`, so nobody reads a skipped term as a satisfied
one.

When the conjunction does not hold, *which* term failed decides the
classification, in the order set out in §9.0.

---

## 9. Failure classification and exit codes

Auth setup makes **no claim about any screen**, so it can never produce
exit 1. Exit 1 means the application is wrong; auth setup is never in a
position to say that. Every failure is "the run is wrong": **exit 2**,
which is the code E-03 and E-04 already use for exactly that news. Usage
errors are **64**. Success is **0**.

| classification | when | class |
|---|---|---|
| `SECRET_MISSING` | a declared reference resolves to nothing. Names the reference, never a value | runnerControlled |
| `INVALID_CREDENTIAL` | the application itself said so: `verify.invalidCredentialOn` holds — it stayed on `/secure-login` and rendered its own error element | humanAction |
| `LOGIN_UI_NOT_FOUND` | a declared element is not in the tree. Carries the available ids, which are ids and not values | applicationControlled |
| `AUTH_REQUEST_FAILED` | the login exchange never happened, or did not answer the declared status | externalService |
| `AUTH_PATH_NOT_SUPPORTED` | the application went to `/otp-verification` or `/registration-otp` — a path that needs a real SMS and cannot be made deterministic without a bypass | applicationControlled |
| `AUTHENTICATED_STATE_NOT_REACHED` | login was accepted and the application did not reach `verify.route` — `/set-location` is the known instance | applicationControlled |
| `AUTH_FLOW_FAILED` | a declared step did not complete - it timed out, or the device refused it | applicationControlled |
| `ENVIRONMENT_PREREQUISITE` | device, build, profile, permissions, or a handshake `appId` that is not the declared one | devicePrerequisite |

> **`AUTH_FLOW_FAILED` was added during implementation, and why.** Measured
> on a real device against a backend that rejected the login: the
> application sat on its own error state, never settled, and the
> `StateError` escaped the runner entirely - exit 255, a stack trace, no
> classification, no remedy and no artefact. A step that does not complete
> is a verdict, exactly as `awaitRoute` not arriving already was.

Each classification carries a remedy, required by the constructor rather
than by convention — E-04's rule, for E-04's reason.

### 9.0 Precedence, because more than one can be true at once

A wrong PIN can produce both a rejected exchange and an error on screen,
and both are true. The classification is decided in this order, and the
order is part of the specification because the most specific answer is
the most useful one:

```
1  ENVIRONMENT_PREREQUISITE       nothing below it could be believed
2  SECRET_MISSING                 nothing was ever typed
3  LOGIN_UI_NOT_FOUND             the flow could not be driven
4  AUTH_PATH_NOT_SUPPORTED        the application went somewhere we refuse
5  INVALID_CREDENTIAL             the application said the credential was wrong
6  AUTH_FLOW_FAILED               a declared step did not complete
7  AUTH_REQUEST_FAILED            the request did not answer as declared
8  AUTHENTICATED_STATE_NOT_REACHED  everything worked and /home did not arrive
```

`AUTH_FLOW_FAILED` sits at 6 for two reasons, and both are tested as
adjacent pairs. Below `INVALID_CREDENTIAL`, because a rejected credential
usually *also* stalls the flow and the application's own verdict is the
sharper one. Above `AUTH_REQUEST_FAILED`, because a flow that stalled may
never have made the authentication request at all, and reporting the
missing request would name a consequence as though it were the cause.

`INVALID_CREDENTIAL` outranks `AUTH_REQUEST_FAILED` deliberately: "your
PIN is wrong" is actionable and "the login request answered 401" is the
same news in a form that sends somebody to look at a backend.

This is a pure function over the observations, and it is the whole of
`auth_verification.dart` — which is what makes the table in §11 testable
without a handset.

**Auth setup never continues after a failed authentication.** There is
nothing after it to continue to: the command's entire product is the
verdict.

### 9.1 `auth.json`

Written on every outcome, including a blocked one, because CI wants an
answer either way and "we could not authenticate" is an answer.

Serialised through an **allow-list** of keys, which is E-04's pattern and
E-04's reasoning — a deny-list only ever catches the secrets somebody
remembered:

```
outcome - classification - remedy - route - routeHistory - loginPerformed
- elementVerified - request{endpoint,status,satisfied} - durationMs
- secretsUsed[]  (references only: "env:MYTEST_AUTH_PIN")
- appId - appVersion - buildMode - deviceModel
```

Specifically absent, and asserted absent by literal: any secret value,
the device serial, any URL, any request or response body, any header, any
UI tree, any image.

`deviceModel`, never the serial — the serial is an address, not an
identity, as E-03 established for baselines and E-04 for preflight.

---

## 10. Device and build boundary

The brief asks eight questions; these are the answers the design commits
to.

| question | answer |
|---|---|
| which device profile | the one the auth file names, resolved by E-04's `loadDeviceProfile`; a profile id, never a serial |
| which build | the `app.target` + `app.flavor` the auth file names, launched by `flutter run -t ... --flavor ...` |
| is an already-installed build accepted | it is replaced. `flutter run` installs the declared target, and an upgrade install with the same signing key preserves application data — which is what carries the session to the suite |
| how the runner verifies it controls the intended application | the handshake's `appId` must equal the declared `appId`; a mismatch is `ENVIRONMENT_PREREQUISITE`. The *build* is the declared one by construction, because the runner built and launched it |
| wrong build or package installed | a package installed under the same id with a different signature fails to install, `flutter run` fails, and the launch error is classified `ENVIRONMENT_PREREQUISITE` rather than reported as a login problem |
| device already authenticated | detected at §7 step 5 and honoured: verified, not re-driven (§11 case B) |
| device signed out | the real login is driven (§11 case A) |
| permissions missing | granted at §7 step 2 when declared, verified at step 3, and a permission the manifest never requested is reported as `not declared` rather than offered a `pm grant` that cannot work — E-04's distinction, E-04's code |

**No unrelated handset is modified.** The permission grant is gated on
the device and profile checks passing, which is E-04's rule, reused
rather than restated.

**Nothing is cleared.** Auth setup declares no state reset and performs
none. `pm clear` appears nowhere in E-05.

---

## 11. State and repeatability

| case | starting state | behaviour | outcome |
|---|---|---|---|
| A | signed out | launch -> `/onboarding` or `/login` -> real login driven -> verify | success, `loginPerformed: true` |
| B | already authenticated | launch -> `/home` -> verify; **no login attempted** | success, `loginPerformed: false` |
| C | invalid credentials | the application rejects its own login request | `INVALID_CREDENTIAL`, exit 2 |
| D | wrong application or build | handshake `appId` mismatch, or the launch fails | `ENVIRONMENT_PREREQUISITE`, exit 2 |
| E | login UI changed or absent | a declared element is not in the tree | `LOGIN_UI_NOT_FOUND`, exit 2 |
| F | authenticated but `/home` not reached | login accepted, final route is `/set-location` or other | `AUTHENTICATED_STATE_NOT_REACHED`, exit 2 |

Case B costs one launch and no login. That launch is not optional: it is
the only way to learn the state without reading what the application
wrote, which E-04 established proves merely that something was written.

Case F has a known cause worth naming. After a successful PIN login the
application calls `goToPostAuthLanding`, which resolves a location gate: a
saved pinned address wins, then a live GPS fix, and with neither the
consumer is sent to `/set-location`. So reaching `/home` requires the
location permissions — which is why the auth file declares them — **and**
the device's location service to be on. A device with location switched
off authenticates successfully and lands on `/set-location`, and E-05
reports that as case F with a remedy naming the location service, rather
than as an authentication failure it is not.

---

## 12. Files

### Platform — `flutter_testsmith`

New:

| file | contents |
|---|---|
| `flutter_testsmith_engine/lib/src/auth/secret_ref.dart` | `SecretRef`, `Secret`, `SecretResolver`, `MissingSecretException` |
| `flutter_testsmith_engine/lib/src/auth/auth_flow.dart` | `AuthFile.parse` and the refusals of §6.1 |
| `flutter_testsmith_engine/lib/src/auth/auth_result.dart` | `AuthSetupResult`, `AuthSetupFailure`, allow-listed `toJson` |
| `flutter_testsmith_engine/lib/src/auth/auth_verification.dart` | the pure classification function of §8 and §9 |
| `flutter_testsmith_cli/lib/src/commands/auth_command.dart` | `AuthCommand` + `AuthSetupSubcommand` |
| `flutter_testsmith_cli/lib/src/auth_runner.dart` | the lifecycle of §7 |
| `flutter_testsmith_cli/lib/src/env_secret_resolver.dart` | `Platform.environment` then `DotEnv` |

Modified:

| file | change |
|---|---|
| `flutter_testsmith_engine/lib/src/dsl/steps.dart` | `SecretInputStep` (must live here; `Step` is sealed) |
| `flutter_testsmith_engine/lib/src/device/device_controller.dart` | `inputSecret` on the interface; redacted command on the exception |
| `flutter_testsmith_engine/lib/src/device/adb_device_controller.dart` | `_adb` display form; `inputSecret` |
| `flutter_testsmith_cli/lib/src/flow_executor.dart` | rejecting case for `SecretInputStep` |
| `flutter_testsmith_engine/lib/flutter_testsmith_engine.dart` | exports |
| `flutter_testsmith_cli/bin/testsmith.dart` | register `AuthCommand` |

### Application — `external_app`

| file | change |
|---|---|
| `lib/features/auth/presentation/screens/secure_login_screen.dart` | `TestId` wrappers only — `secure_login.pin_field`, `secure_login.continue_button`, `secure_login.pin_error`. No behaviour change; the same pattern `login_screen.dart` already uses |
| `mytest/auth/uat.yaml` | new, as §6 |
| `mytest/suites/regression.yaml` | the `authenticated` precondition's `remedy:` names the command. Text only |

The PIN screen currently carries no test ids at all, and
`ElementLocator` resolves by test id only. Without the wrappers the real
login UI is undrivable past `/login`, and the only alternative is
coordinate tapping, which ADR-0006 rejected.

---

## 13. Tests

Every item the brief's §9 lists, mapped to where it is proved.

| item | test |
|---|---|
| secret reference resolution | `secret_ref_test` — `env:NAME` parses; env beats `DotEnv` |
| missing secret | `secret_ref_test` + `auth_command_test` — `SECRET_MISSING`, exit 2, nothing launched |
| secret never in reports | `auth_leakage_test` — seeded literals absent from `auth.json` |
| secret never in logs | `auth_leakage_test` — every `log()` line captured and searched |
| secret never in exception messages | `device_secret_input_test` — `DeviceCommandException.toString()` after a failed `inputSecret` |
| sensitive input not in step descriptions | `auth_flow_test` — `SecretInputStep.describe()` renders the reference |
| token not in output | `auth_leakage_test` — seeded token absent from every artefact |
| failed authentication | `auth_verification_test` — `INVALID_CREDENTIAL`, `AUTH_REQUEST_FAILED` |
| successful authentication | `auth_verification_test` — all terms satisfied |
| already-authenticated state | `auth_verification_test` — `loginPerformed: false`, request term skipped not satisfied |
| wrong build or device | `auth_verification_test` — handshake `appId` mismatch |
| setup cleanup | `auth_runner_test` — dispose runs after success and after failure; a failing step is recorded, never raised |
| the parser's refusals | `auth_flow_test` — `screenshot`, `validateScreen`, `input` each rejected with a reason |
| classification precedence | `auth_verification_test` — an observation set that satisfies two rules yields the higher one, for every adjacent pair in §9.0 |
| presence is checked without reading | `secret_ref_test` — `isPresent` returns a bool and a recording resolver proves no value was read |
| `Secret` cannot be interpolated | `secret_ref_test` — interpolating a `Secret` yields `[REDACTED]` |
| exit codes | `auth_command_test` — 0, 2, 64 against the real executable |

The leakage tests seed values into `MYTEST_AUTH_MOBILE` and
`MYTEST_AUTH_PIN` and search the **serialised bytes for the literal**,
which is the discipline `secret_leakage_test` and `report_leakage_test`
already use: checking that the right keys were redacted proves only that
the redactor did what it was told.

### Regression

All platform tests; `dart analyze --fatal-infos`; the existing external_app
tests; the E-04 five-flow suite; the CLI exit-code tests; the existing
leakage tests. E-04's eight Login findings compared field for field on
validator, element and message.

---

## 14. Acceptance

On the Samsung SM-M127G and the real UAT build, no fake authentication
path.

1. **RUN 1** — device signed out; `testsmith auth setup`; credentials from
   the secret reference; the real login UI driven; `/home` reached; no
   credential or token in any artefact; exit 0.
2. **RUN 2** — without signing out; `testsmith auth setup` again; the
   already-authenticated state recognised; no second login; exit 0.
3. **The E-04 suite afterwards**, unchanged: `home`, `orders`, `profile`,
   `journey` PASS; `login` FAIL with the same eight Figma findings,
   field for field; `4 PASS / 1 FAIL / 0 ERROR / 0 SKIP`; exit 1.
4. **A leakage audit** over every file all three produce.

---

## 15. Known limitations, carried into the doc

1. **The PIN path only.** An account without a PIN goes to OTP, which
   needs a real SMS and cannot be made deterministic without a bypass.
   E-05 detects that path and refuses it by name rather than timing out.
2. **`mobileNumber` is not redacted by the SDK's global policy.** Auth
   setup writes no bodies, so it does not leak there — but the value is
   in the application's own capture buffer in memory, and a *future*
   feature that serialised bodies would expose it. A follow-up for
   whoever owns `RedactionPolicy`; changing it in E-05 would alter E-04's
   existing `profile` artefacts.
3. **Two full builds per acceptance cycle**, because auth setup and the
   suite launch different entry points of the same package.
4. **`signedOutOn` and `verify.route` are human declarations**, as
   E-04's `unmetOn` is. The runner never infers them, which is the point,
   and it also means a wrong declaration is not detectable by the runner.
5. **Android only**, as everything below this layer already is.
6. **No session is ever torn down.** Auth setup establishes; it has no
   sign-out. `login`'s `reset: clearState` remains the only thing that
   signs the device out, exactly as in E-04.
