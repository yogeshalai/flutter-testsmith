# E-03 — Suite runner, device profiles, baseline selection

Turning individual deterministic flows into one reproducible run.

Read this if you are about to write a suite, add a device, or work out
why a baseline was refused.

---

## 1. The suite format

A suite is an ordered list of flows and what to arrange between them.

```yaml
suite: example-regression

app:
  path: ../..                       # relative to this file
  target: lib/main_mytest.dart
  flavor: example

device:
  profile: samsung-m127g            # a profile id, never a serial

mockApi:
  port: 8080

onFailure: continue                 # or `stop` for fail-fast

tests:
  - id: home
    flow: mytest/tests/home.yaml    # relative to the app root
  - id: orders
    flow: mytest/tests/orders.yaml
  - id: login
    flow: mytest/tests/login.yaml
    reset: clearState
    grant: [android.permission.POST_NOTIFICATIONS]
  - id: journey
    flow: mytest/tests/journey.yaml
    optional: true
```

| Key | Meaning |
|---|---|
| `id` | The stable test identity. Names a row in the report and a directory on disk, so it must be unique — and is chosen rather than derived from a path, because a path changes when a file moves and a result that changes identity when a file moves cannot be compared with yesterday's. |
| `flow` | The flow file, relative to the app root — the way a person refers to it from the project. |
| `reset` | `none` (default) or `clearState`. |
| `grant` | Permissions to grant after a reset. |
| `optional` | Whether the suite can pass without this test. Default false. |
| `onFailure` | `continue` (default) or `stop`. |

**There is no discovery, and there will not be one.** A suite is a list
somebody wrote, in the order they wrote it. A suite that finds its own
contents silently changes what it tests when a file appears, and the
first anyone knows of it is a result that moved for no reason in a diff.

Ordering is load-bearing, and the real suite shows why: `login` declares
`reset: clearState`, which signs the device out, so it runs **last**.
Put it first and the four flows after it sit on `/login` and report four
failures the suite caused itself.

Parsing rejects, rather than ignores: an unknown key at any level, a
duplicate `id`, a test with no `id` or no `flow`, an empty `tests` list,
a missing `device.profile`, an unknown `reset` or `onFailure`. A typo
that is silently ignored is a setting that silently does nothing.

---

## 2. Execution model

```
                     ┌─ testsmith run <flow>  ──┐
                     │                       ├──▶ FlowRunner ──▶ FlowExecutor
   testsmith suite run ─┴─▶ SuiteRunner ────────┘
```

There is **one** execution path. `FlowRunner` is the middle of what
`testsmith run` has always done — point the fixture server at the state the
flow names, launch the application, record what the run is happening on,
execute, tear down — lifted into its own unit. Both commands call it.

That is the whole reason the refactor happened first: "a flow behaves the
same alone as in a suite" is then a property of the structure rather than
a promise in a document. `SuiteRunner` does orchestration only —
ordering, lifecycle, fail-fast, aggregation — and executes nothing
itself.

`SuiteRunner` takes a `FlowExecution`, so ordering, fail-fast, lifecycle
and aggregation are tested against a fake with no device attached.

Stages, in order, each of which can end the run before the next begins:

1. suite syntax
2. every flow it names exists — checked before anything is built, because
   there is no point compiling an application to discover a path typo
3. the device profile parses and exists
4. a device is attached and usable
5. the connected device *is* the one the profile describes
6. the fixture server starts, once, for the whole suite
7. tests run in declared order
8. results aggregate
9. `suite.json` and `suite.html` are written

---

## 3. Lifecycle

```
suite setup    resolve + verify profile, start the fixture server
  per test     reset (only if declared) → grant (only if declared)
               → swap the API scenario → launch the app
               → run the flow → dispose the session
suite teardown stop the fixture server
```

Three decisions worth stating:

**The application is relaunched for every test.** That is what a single
run does, so a suite whose tests saw a different starting state would be
measuring something else.

**State is cleared only where the suite says so.** A runner that wiped
the device between every test would spend its life re-signing-in, and
would make each test's real precondition invisible. `clearState` lives in
the *suite*, not in the flow DSL — putting it in the DSL would give every
flow a way to reach into the device.

**The fixture server keeps running and swaps scenarios in place.**
Restarting it between tests would tear down the `adb reverse` the device
talks through. The exchange log is cleared with each swap: exchanges are
what an API assertion reads, and carrying the previous test's requests
forward would let a flow assert against traffic it never made.

`grant:` is not decoration. Clearing an application's state also revokes
what the user granted it, and Android then draws its notification
permission dialog over the bottom of the onboarding screen — exactly
where "Get Started" is. The tap lands on the dialog, and the run reports
a tap that happened and a navigation that did not. That cost half a day
during E-02 and is why the option exists.

---

## 4. Device profiles

```yaml
id: samsung-m127g
model: SM-M127G
os: Android 13
physical: {width: 720, height: 1600}
devicePixelRatio: 1.875
orientation: portrait
buildMode: debug
```

**A serial number is not an identity.** `RZ8T11QETWM` is the handset on
one desk; it says nothing about the conditions a picture was recorded
under, and binding a baseline to it would mean the baseline could only
ever be checked on the machine that took it — the opposite of what a
committed baseline is for.

What makes two runs comparable is the model, the OS, the resolution, the
pixel ratio, the orientation and the build mode. A profile names those,
is stable across every device of that kind, and is chosen by a person —
so it can be written into a baseline path and reviewed like any other
file.

The logical viewport is **derived**, not declared: two numbers that must
agree are one number and an opportunity to get it wrong. The
application's own version is deliberately absent — it changes with every
build, so declaring it would make the profile a thing somebody maintains,
and a maintained provenance note is a stale one. It is read from the
handshake and recorded in the result.

Verification happens in two halves, because the facts arrive from two
places. Model, OS and resolution come from `adb` and are checked before
anything is launched. Pixel ratio and build mode come from the SDK
handshake and are checked on the first launch. A contradiction is an
ERROR, not a warning: a device that is not the one the profile names
makes every baseline comparison meaningless.

A fact the device did not report is **not** a mismatch. A runner that
could not read the OS has learned nothing about it, which is different
from learning a disagreement.

---

## 5. Baseline selection

Candidates for `(screen, fixture, profile)`:

| Path | |
|---|---|
| `visual_baselines/<profile>/<screen>@<fixture>.png` | profile-scoped |
| `visual_baselines/<screen>@<fixture>.png` | legacy, flat |

| Outcome | Condition |
|---|---|
| **selected** | exactly one candidate exists, and its recorded resolution and pixel ratio match the profile |
| **ambiguous** | both exist — refused, naming both paths |
| **missing** | neither exists — the paths searched are reported |
| **incompatible** | found, but recorded under a resolution or pixel ratio that contradicts the profile |

**There is no "closest match", and there will not be one.** The closest
match to a picture of a different device is still a picture of a
different device. Before this existed, a baseline recorded at 1080×2400
resolved happily against a 720×1600 device and the comparison reported a
screen that had not changed as different in every pixel — true, and
useless.

Compatibility is resolution and pixel ratio only. Those are the two that
make the comparison arithmetically wrong. A model or OS difference at the
same geometry is recorded in the metadata and surfaced in the report, but
does not by itself make two pictures incomparable — and the profile-scoped
path is itself an assertion about which profile a picture belongs to.

Legacy flat baselines still resolve, so every baseline committed before
profiles existed keeps working. They are checked just as strictly: being
old is not a reason to be trusted. `testsmith run`, which has no suite and
therefore no profile, behaves exactly as it did before.

Every outcome above is what the **visual validator** acts on, not a
library a caller may consult. Ambiguous and incompatible are ERRORs;
missing records a first baseline and skips, as it always did. This is
worth stating because it was not true until the acceptance gate caught
it: selection existed, was tested, and was not called - see §11.

A selected baseline is also **recorded in the result**, on pass and on
failure alike:

```json
"evidence": [
  {"kind": "baseline",         "reference": "visual_baselines/orders@orders_populated"},
  {"kind": "deviceProfile",    "reference": "samsung-m127g"},
  {"kind": "resolution",       "reference": "720x1600"},
  {"kind": "devicePixelRatio", "reference": "1.875"},
  {"kind": "compatibility",    "reference": "compatible"},
  {"kind": "baselineLayout",   "reference": "legacy"},
  {"kind": "ssim",             "reference": "1.0000"}
]
```

A green tick that does not say which file produced it cannot be checked
by anyone. Where a baseline records no pixel ratio - the ones written
before that metadata existed - the `devicePixelRatio` line is absent
rather than guessed.

---

## 6. Aggregate verdicts

Precedence is **ERROR > FAIL > PASS**, and SKIP outranks nothing.

| Verdict | When |
|---|---|
| **ERROR** | any *required* test errored, or a required test did not run |
| **FAIL** | else any *required* test failed deterministically |
| **PASS** | else every required test passed |
| **SKIP** | only when nothing was required and everything skipped was optional |

ERROR above FAIL because the two say different things. A FAIL is a defect
somebody can act on; an ERROR is the absence of an answer. A suite that
could not evaluate a required test does not know whether it passes, and
reporting that as a plain failure would claim knowledge it does not have.

SKIP below everything because a skip is the easiest verdict to produce by
accident — a missing file, a stopped run, a typo in an id — and a skip
that could outrank a failure would be a suite that goes green by not
running. **A required test that was skipped counts as an ERROR, not a
pass.** Fail-fast leaves later tests unrun, and a test that did not run
has not been shown to be correct.

A test is ERROR rather than FAIL when the application would not start,
the flow could not be parsed, the device is not the profile's, or a flow
names an API state with no fixture server to arrange it. None of those is
the screen being wrong.

**No model participates.** An explanation may be attached to an
individual run afterwards; it cannot move any of this.

---

## 7. Exit codes

| Code | Meaning |
|---|---|
| `0` | PASS — or SKIP, which by definition skipped nothing required |
| `1` | FAIL — something is wrong with the application |
| `2` | ERROR — something is wrong with the run |
| `64` | usage, matching what `testsmith run` already returns |

1 and 2 are distinguished because they need different people: a 1 goes to
whoever wrote the screen, a 2 to whoever owns the device or the fixture.

Verified end to end:

```
no argument (usage)                        64
no such suite file                          2
invalid syntax                              2
missing flow                                2
real suite, no device attached              2
```

0 and 1 are asserted against `SuiteResult.exitCode`, which the command
returns directly.

---

## 8. The JSON report

`<out>/suite.json`, with each test's existing `result.json` and
`report.html` under `<out>/<testId>/`.

```json
{
  "suiteSchemaVersion": "1.0",
  "suite": "example-regression",
  "deviceProfile": {"id": "samsung-m127g", "model": "SM-M127G", ...},
  "appVersion": "1.0.6",
  "buildMode": "debug",
  "startedAt": "...", "durationMs": 252000,
  "verdict": "fail",
  "exitCode": 1,
  "counts": {"pass": 4, "fail": 1, "error": 0, "skip": 0},
  "tests": [
    {
      "id": "login",
      "verdict": "fail",
      "required": true,
      "durationMs": 61000,
      "output": "login",
      "checks": {
        "steps": 7, "screens": 1, "apiChecks": 0,
        "failures": [{"screen": "/login", "validator": "figma-geometry",
                      "element": "login.card", "message": "..."}],
        "errors": [], "skips": [...]
      }
    }
  ]
}
```

`suite.html` is rendered from this decoded JSON, as the run report
already is, so the page is a pure function of the file CI consumes and
the two cannot drift apart.

---

## 9. CI usage

```bash
testsmith suite run mytest/suites/regression.yaml --out results/
```

No interactive prompts, stable paths, machine-readable output, and a
non-zero exit on a deterministic failure.

**A physical Android device is an environment requirement.** The suite
drives a real application on real hardware; there is no emulator path and
no cloud device farm, and building one is explicitly out of scope. CI
therefore needs a host with a device attached and `adb` on the path. The
suite fails with exit 2 and a plain message when there is none.

---

## 10. Security

A suite report carries the profile, the app version and the build mode,
and **nothing else about the machine**. No serial, no environment, no
credentials.

This is asserted as an **allow-list** of the keys a report may contain
rather than a deny-list of known secrets — a deny-list only ever catches
the secrets somebody remembered. The same test covers the device profile.

Everything E-02 established still holds: the Figma token appears in no
spec, cache file, report or exception message, and the redaction test
that proves it is still run.

---

## 11. Real-device evidence

Samsung SM-M127G, Android 13, 720×1600, density 300 (dpr 1.875),
`user_rotation 0`. Every fact the profile declares was read off the
device and matched before the run.

```
testsmith suite run mytest/suites/regression.yaml -d RZ8T11QETWM --out out/e03-suite
```

### Getting to a signed-in device, and what that cost

The first run failed all five tests identically — *expected to be on
"/home" within 40s but the app is on "/login"* — and the fixture server's
own log named the first cause:

```
404  GET /getUnatherizedToken   ! no route in "default"
```

The application asks for a guest token at `/getUnatherizedToken`, and no
scenario modelled that route: it sits outside the `/api/*` catch-alls.
The response **shape** was not guessed. It was read from the application's
own source and from the application's own test
(`test/features/auth/guest_token_test.dart`): the token arrives in the
`x-auth-token` **response header** and the body is unused. One route was
added to `default.json` accordingly, and the device confirmed it —
`flutter.guest_token = FIXTURE_GUEST_TOKEN_e3a1`.

That was necessary and not sufficient, and the reason is a design
decision in the application, not a gap in the runner: `fetchGuestToken`
sets `is_logged_in = false`, and `splash_screen.dart` routes every
un-logged-in user to `/login` on cold start. A guest token gets the app
past its network call and no further.

The remaining options were to fake a login response or to sign in for
real. A fixture login was rejected on inspection: scenario routes match
on **method and path only**, so a `/login/consumer` fixture would accept
*any* PIN — an authentication bypass wearing a test fixture's clothes.

So the device is signed in through the application's real flow, out of
band and before the suite: the genuine UAT build
(`main_example.dart`, `.env.uat`) against the real UAT
backend, driven through its real UI — onboarding, `/isconsumerexist`,
the six-digit PIN screen, `POST /login/consumer` — reaching a
personalised `/home`. Same flavour means same package id means same
storage, so the mytest build inherits the session.

Three constraints shaped how, and are worth stating because each one
rules out a shortcut that would have been easier:

- Nothing internal was written. No `is_logged_in`, no token storage, no
  SharedPreferences flag, no router state. The evidence that it worked is
  observable behaviour — the app greeted the account by name — not a
  value read back out of storage, which would only prove that something
  had been written.
- The credential never entered the runner. `InputStep.describe()` renders
  `type "<value>" into "<elementId>"`, which is exactly right for a test
  step and exactly wrong for a PIN: it would have put the credential in
  `result.json`, in `report.html` and in the console. The sign-in is
  driven with `adb` directly, credentials held only in environment
  variables outside both repositories.
- No application authentication logic was modified.

This is the precondition the suite file has always documented, closed
rather than removed. **The suite still cannot sign itself in**, and
§12.2 stands.

### A second precondition, found by running signed in

The first authenticated run reported two tests as ERROR:

```
orders   error   480s   The app did not start within 8 minutes.
profile  error   480s   The app did not start within 8 minutes.
```

A screenshot taken while it was stuck showed why: Android's **location**
permission dialog, drawn over the launcher, with the application not
running at all. A signed-in launch asks for location, the system dialog
takes the foreground before the app finishes starting, and the handshake
never arrives. It is the same failure family as the notification dialog
that `login` already documents — a runtime permission the application
asks for at exactly the wrong moment.

Confirmed rather than assumed: dismissing the dialog by hand let the two
remaining tests start normally, in 73s and 42s. Granting the permission
up front removed it entirely, and the accepted run below launched five
times without a single dialog.

Classified **PRECONDITION/device**. The runner is not at fault: it waited,
it timed out, and it said so. Recorded in `mytest/suites/regression.yaml`
beside the sign-in precondition, including the ordering interaction that
makes it recur — `login`'s `reset: clearState` revokes these grants along
with everything else, so the next authenticated run has to re-grant them.

What the suite did with it is the part worth keeping:

- both tests were **ERROR**, not FAIL — the suite could not evaluate them,
  and saying "failed" would have claimed knowledge it did not have;
- the aggregate became **ERROR**, exit **2**, not the `fail`/1 the other
  three tests would have produced on their own;
- neither test was given an output directory, because neither ran.

That is the verdict precedence and the reporting rule doing their job on
hardware, on a condition nobody designed a test for.

### The accepted run

```
example-regression
  device profile  samsung-m127g (SM-M127G)
  tests           5, onFailure: continue
  mock API        http://127.0.0.1:8080

PASS  home               57.1s
PASS  orders             57.0s
PASS  profile            58.1s
PASS  journey            59.7s
FAIL  login              53.7s

RESULT: FAIL  (exit 1)
```

Aggregate `fail`, exit `1`, counts `{pass: 4, fail: 1, error: 0, skip: 0}`,
duration 285s. Declared order preserved. `appVersion 1.0.6`,
`buildMode debug`, read from the handshake.

All four signed-in flows reach `/home` and pass. `login` is red, on its
eight known design differences and nothing else.

### Where the real backend stops and the fixtures start

Authentication touches the real UAT backend. The tests do not. The
boundary is the build:

```
  real authentication setup          deterministic test environment
  ─────────────────────────          ──────────────────────────────
  uat.apk                            lib/main_mytest.dart
  .env.uat                           .env.mytest
  API_BASE_URL = <redacted UAT host> API_BASE_URL = http://127.0.0.1:8080
  driven once, by hand, via adb      driven by the runner, every test
                        │
                        └── shared package id ⇒ shared storage ⇒ session
```

Same flavour, same package id, so the session the UAT build obtained is
the session the mytest build finds. Nothing is copied, written or
injected; the two builds simply read the same application storage.

**Measured, not assumed.** Every flow was re-run standalone so the
fixture server would print what it answered — the suite does not print
this (see limitation 11). Across the five flows the mock served **48
requests, 0 unmatched**:

| flow | requests served by MockApiServer | asserted | from the real backend |
|---|---:|---:|---:|
| home | 13 — appconfig, mobileversion, appmaintenance, profile, notifications count, cartdata, dashboard ×2, and 5 `/fixtures/*.png` | 1 | 0 |
| orders | 9 — the same startup set, plus billing and requests | 1 | 0 |
| profile | 8 — startup set plus dashboard ×2 | 0 | 0 |
| journey | 10 — startup set, dashboard ×2, billing, requests | 2 | 0 |
| login | 3 — mobileversion, appmaintenance, appconfig | 0 | 0 |

Every response, including the screens' images, comes from the fixture
server: the image URLs in `dashboard_populated.json` are
`http://127.0.0.1:8080/fixtures/*.png` and are declared as routes in that
same scenario. `GET /mobileversion/Consumer/android` answers **500** in
every flow — deliberately, in the fixture, and identically each time.

The strongest evidence is an experiment rather than a log. With the
device's **Wi-Fi and mobile data both switched off** — `adb reverse` runs
over USB, so loopback survives — the app still launched, settled, reached
`/home` and passed automatic validation. An application that needed UAT
could not have done that.

**What happens when UAT is unavailable:** the five flows are unaffected,
because they never address it. Only the authentication *setup* needs it,
and only once per signed-out device. A suite run on an already-signed-in
device needs no UAT at all.

### The one thing that is not mocked

That same offline experiment found the limit of the claim, so it is
stated rather than glossed. With the radios off the run **failed** a
later step:

```
1 unexpected animation running: Lottie at 96,196 192x192
```

That is `no_network_connection_view.dart`, which draws
`Lottie.asset(noInternetLottie, width: 192, height: 192)` — the exact
geometry the runner reported. The application watches **device
connectivity** through `connectivity_plus`, which is a platform signal,
not an HTTP request, so no fixture server can answer it.

So the precise statement is: **no unmocked network *request* can affect a
verdict — every Dart-level HTTP request went to the fixture server — but
an unmocked network *condition* can.** The suite is deterministic with
respect to API responses, and it requires the device to have a network
interface up. It does not require any particular backend to be reachable.

`firebase_messaging` and `google_maps_flutter` are linked into the
application and can reach the network natively, below the SDK's
`HttpOverrides` capture. None of the five screens renders a map, and no
asserted value derives from either.

### Where the credential lives

Supplied only as environment variables (`MYTEST_AUTH_MOBILE`,
`MYTEST_AUTH_PIN`) read from a file in the session scratchpad, outside
both repositories, deleted after use. It is typed into the application's
own UI by `adb`, never through the flow runner — `InputStep.describe()`
renders `type "<value>" into "<elementId>"`, which would put it in
`result.json`, `report.html` and the console.

The authentication setup is reproducible but **manual**: it is a sequence
of `adb` taps against the real UI, not a flow the runner can execute.
That is the same fact as limitation 2, seen from the other side.

### Baseline selection, exercised and recorded on hardware

Four visual comparisons ran across the four passing tests, and each one
records what it compared against:

| test | screen | baseline | profile | resolution | dpr | compatibility | result |
|---|---|---|---|---|---|---|---|
| home | `/home` | `visual_baselines/home@dashboard_populated` | samsung-m127g | 720×1600 | 1.875 | compatible | 0.000% differ, ssim 1.0000 |
| orders | `/orders` | `visual_baselines/orders@orders_populated` | samsung-m127g | 720×1600 | 1.875 | compatible | 0.000% differ, ssim 1.0000 |
| profile | `/profile` | `visual_baselines/profile` | samsung-m127g | 720×1600 | *not recorded* | compatible | 0.000% differ, ssim 1.0000 |
| journey | `/orders` | `visual_baselines/orders@orders_populated` | samsung-m127g | 720×1600 | 1.875 | compatible | 0.000% differ, ssim 1.0000 |

All four resolved to the legacy flat layout, and each says so
(`baselineLayout: legacy`) rather than resolving quietly. Compatibility
was asserted before a pixel was read; nothing was chosen as "closest".

`/profile`'s row is the honest one. That baseline predates pixel-ratio
metadata, so it has none to check, and the evidence therefore carries no
`devicePixelRatio` line at all. The absence is the record: three
baselines had a ratio to compare and one did not, and the report does not
invent a number to fill the column.

No baseline was written. `git status visual_baselines/` is empty after
the run — a store that re-records on difference is a suite that can never
fail the same way twice.

### Criterion 11 — the Login findings are untouched

The Login flow ran inside the suite and produced **the same eight Figma
failures** as its committed standalone E-02 result, compared field by
field on validator, element and message, four ways:

```
E-02 committed = 8   standalone = 8   suite report = 8   suite aggregate = 8

E-02 == E-03 standalone      : True
E-03 standalone == suite rpt : True
suite report == suite agg    : True
coverage identical           : True
```

The coverage line is identical too — *181 nodes in the "Login" frame, 90
comparable, 11 mapped, 11 compared, 79 unmapped, 12.2%, 42 passed, 8
failed, 0 errored, 10 skipped, verdict scope: mapped elements only.*
Aggregation neither hid, rewrote nor softened any of it. The suite is red
because of them, which is the point.

That comparison also settles criterion 2: `testsmith run` behaves exactly as
it did before the `FlowRunner` extraction.

### Lifecycle

`login` declares `reset: clearState` and the notification grant, and runs
last. Both were applied to it and to nothing else — the four flows before
it were left alone, which is the default the design insists on.

The application launched exactly **five** times, once per test. No retry
happened, and none is implemented. Where a step description repeats
inside a test (`wait for the screen to settle` appears twice in `orders`
and `journey`), the flow file declares it twice; it is not the same step
run again.

### Verified alongside

| | |
|---|---|
| `suite.json` agrees with `suite.html` | suite name, verdict, exit code, profile id, every test id, every count |
| Every executed test has a report | `result.json` + `report.html` under `out/e03-suite/<testId>/` for all five; no orphan directories |
| Step counts agree | each test's aggregate step count equals its own `result.json` |
| No credential leakage | the PIN, the mobile number and the authorised test credential appear in no source file, YAML, fixture, report, log or diff in either repository; the only matches anywhere were a coincidental digit run inside gitignored Dart kernel caches |
| No secrets in any artefact | Figma token, AI key and the mock session cookie absent from every output file |
| No device serial in `suite.json` | absent — the profile is the identity. It does appear in each per-test `result.json`, where it is provenance of that one run rather than the identity of a baseline, and where it predates E-03 |
| No retry | 5 launches for 5 tests |
| Full regression | 1 461 platform tests, 1 173 application tests, analyzer clean, all dependency rules hold |
| Evidence matrices | all five differ from committed only in their generation timestamp — zero verdict changes |

### The platform test count, per package

Stated so the total is checkable rather than trusted. Measured by running
each package at `fb88fde` (in a worktree) and at this commit:

| package | fb88fde | 66967fa | |
|---|---:|---:|---:|
| root `test/` | 22 | 22 | |
| flutter_testsmith_protocol | 96 | 96 | |
| flutter_testsmith_engine | 711 | 784 | +73 |
| flutter_testsmith_cli | 88 | 104 | +16 |
| figma_client | 78 | 78 | 3 network tests self-skip |
| ai_client | 20 | 20 | |
| flutter_testsmith | 273 | 273 | |
| examples/ecommerce_app | 84 | 84 | |
| **total** | **1 372** | **1 461** | **+89** |

No package lost a test. `git diff --numstat fb88fde 66967fa` over every
`test/` path is **+1602 −0**: not one deleted line, so no test was
removed, renamed, merged, or had an assertion weakened. The only
deletions in the commit are production code - 125 lines from
`run_command.dart` (the `FlowRunner` extraction) and 38 from
`visual_validator.dart` (the selection rewire) - plus five evidence-matrix
timestamps.

An earlier draft of this table said 1 439. That figure was wrong: it
omitted the root package's 22 tests while including the six added during
the gate. The repository never lost anything; the arithmetic did.

### Three defects this gate found

**Selection was built and never called.** `BaselineStore.select` — the
whole `BaselineSelection` hierarchy, eleven tests against real files —
was not on the execution path. `VisualValidator` called `read()`, which
returns the first candidate that exists. So on hardware, two baselines for
one screen would have been resolved by directory order, and a baseline
recorded on different hardware would have been compared against anyway.
Both cases went green in a RED test before the fix: a two-candidate store
**passed**, and a baseline recorded at dpr 3.0 compared against a 1.875
profile **passed**. Ambiguity and incompatibility are now ERRORs naming
the paths and the reasons, and six tests hold it there. This is exactly
what "never silently select the closest baseline" was supposed to prevent,
and it took running the acceptance gate to notice that the rule lived in a
library nobody called.

**A pass that could not be checked.** A green visual comparison said
nothing about which file it compared against. It now records the baseline
path, the profile, the resolution, the pixel ratio and the compatibility
verdict, on pass and on failure alike — the table above is read straight
out of `result.json`.

**Reports nobody wrote.** The suite recorded an `output` directory per
test and the HTML linked to it, but only `testsmith run` wrote `result.json`
and `report.html`. A path to a report that does not exist is worse than no
path: it looks like evidence. Fixed by extracting the writer into
`writeRunReports` and calling it from both, with three tests covering a
passing test, a failing test, and a test that never ran — which gets no
directory, because an empty report would read as "we looked and found
nothing wrong".

### And one in my own artefacts

I re-pulled `figma/home.json` while passing the *Login* mapping file,
which stamped eleven Login node bindings onto the Dashboard design;
`home` and `journey` then reported eleven `figma-mapping` stale-mapping
ERRORs. The validator was right and the input was wrong. Re-pulled without
`--mapping`; `unmatchedMappings` back to 0, `login.json` untouched at 11
mapped. Recorded because a tool that loudly refuses bad input is the
behaviour worth keeping, and because the alternative account — quietly
fixing the file and reporting five clean tests — would have hidden the one
moment in this milestone where the validator caught *me*.

## 12. Limitations

1. **A device is required, and there is no emulator path.** Out of scope
   by instruction, but it is the reason CI cannot run this on a plain
   build agent.
2. **The suite cannot establish its own signed-in state.** It documents
   the precondition instead. A `setup:` phase that runs a flow whose
   result is not aggregated would fix this, and was not built because
   E-03 produced no evidence that it is the right shape.
3. **One device per suite.** A suite names one profile and runs against
   one handset. Running the same suite across a matrix of profiles is the
   obvious next step and is not here.
4. **Tests run in sequence.** No parallelism, and with one device there
   is nothing to parallelise onto.
5. **The application is rebuilt and relaunched per test**, which costs
   30–60s each. Correct, and the reason a five-flow suite takes minutes.
6. **Baseline compatibility is resolution and pixel ratio only.** A
   model or OS difference at identical geometry is reported but not
   refused.
7. **`suite.html` does not embed screenshots or diffs.** It links each
   test to its own report, which does.
8. **No retries, and deliberately so.** A flaky test that passes on the
   second attempt is a flaky test, and a runner that hides that is a
   runner that lies.
9. **Baselines are not keyed by authentication state.** A baseline is
   filed by screen, API fixture and device profile. Two runs in
   different sign-in states are compared as though identical, and the
   difference surfaces as a visual failure rather than as an
   incompatible baseline. Compatibility checks geometry, not session.
10. **A system permission dialog stops a run without explaining
    itself.** The runner reports "the app did not start within 8
    minutes", which is true and does not say that Android is holding the
    foreground. Detecting that would mean the runner inspecting the
    window manager; it is written down in the suite file instead.
11. **The suite does not print what the fixture server served.**
    `testsmith run` does, and an unmatched route is called out there; the
    suite path never calls that reporter. A scenario missing a route the
    application really uses is therefore visible in a single run and
    invisible in a suite. Establishing the traffic table above meant
    re-running all five flows standalone.
12. **The device must have a network interface up.** Not a backend - an
    interface. The application watches `connectivity_plus`, which is a
    platform signal no fixture server can answer, and draws a
    no-connection view when it is down. See "The one thing that is not
    mocked".
