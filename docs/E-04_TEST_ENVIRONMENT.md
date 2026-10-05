# E-04 — Test environment and setup lifecycle

Making the deterministic environment reproducible without hiding what it
needs.

Read this if a suite refused to run, if you are adding a prerequisite, or
if you want to know why a result says ENVIRONMENT rather than FAIL.

---

## 1. The environment model

E-03 could run five flows against a real handset and report honestly on
what it measured. What it could not do was say why it had failed to
measure anything. A signed-out device produced four product failures
blaming four screens; a revoked location permission produced two ERRORs
saying "the app did not start within 8 minutes", which was true and did
not mention Android holding the foreground.

E-04 adds one distinction and builds everything else on it:

> **A result says something about the application, or it says something
> about the run.** Never both, and never the first when it is the second.

The application half is unchanged: PASS and FAIL mean exactly what they
meant in E-03. The run half is folded onto the existing **ERROR** verdict,
which already meant "the run did not answer the question" and already
exits 2. No new verdict, no new exit code, no new aggregate semantics —
E-03's precedence (ERROR > FAIL > PASS, SKIP outranks nothing) governs
both halves untouched.

The report therefore answers the question it could not answer before:

```
ERROR home    ENVIRONMENT precondition   the application ended on "/login"
FAIL  login   PRODUCT                    8 figma-geometry differences
```

Two rows, two people. The first goes to whoever owns the device; the
second to whoever owns the screen.

---

## 2. Prerequisite classification

Every prerequisite the E-03 five-flow suite actually requires, read off
the code and measured on a Samsung SM-M127G.

| Prerequisite | Class | Established by | Readable before launch? |
|---|---|---|---|
| app state (stored data) | RUNNER_CONTROLLED | `reset: clearState` → `pm clear`, per test, only where declared | yes |
| **authentication** | **HUMAN_ACTION** | the real UAT build's own login UI, driven by hand | **no** — §5 |
| notification permission | RUNNER_CONTROLLED | `grant:` on the `login` test | yes |
| location permission | RUNNER_CONTROLLED *(was DEVICE_PREREQUISITE)* | `device.permissions:`, granted at setup | yes |
| other runtime permissions | not required | never requested by the five flows | yes |
| **network interface** | **DEVICE_PREREQUISITE** | the handset having an active default network | yes |
| mock API server | RUNNER_CONTROLLED | started once per suite on the declared port | yes |
| mock scenario | RUNNER_CONTROLLED | `fixture:` per flow, swapped in place | yes |
| SDK armed | APPLICATION_CONTROLLED | `bool.fromEnvironment('TEST_MODE')` in the app's own bootstrap; the runner always passes `--dart-define=TEST_MODE=true` | no — arrives in the handshake |
| baseline availability | RUNNER_CONTROLLED | files in `visual_baselines/` | yes |
| device profile (the file) | RUNNER_CONTROLLED | `device_profiles/*.yaml` | yes |
| device profile (the handset) | DEVICE_PREREQUISITE | `adb getprop`, plus the handshake half at first launch | half |
| app build | RUNNER_CONTROLLED | `flutter run` builds it; the entry point must exist | yes |
| app installed | RUNNER_CONTROLLED | installed by the first launch | yes |
| app launch | RUNNER_CONTROLLED | one launch per test | n/a |
| splash state | APPLICATION_CONTROLLED | the app's own router; `/login` when it holds no session | no |
| UAT backend | EXTERNAL_SERVICE | **only** authentication setup ever addresses it | n/a |

Two classifications changed during E-04, and both changed because
something was *declared* rather than because anything new became
possible. Location was a device prerequisite only because nothing named
it; it is now a line in the suite file. Authentication is a human action
only because automating it would mean bypassing the thing it establishes
(§5).

`PrerequisiteClass` is in
[`prerequisite.dart`](../packages/flutter_testsmith_engine/lib/src/environment/prerequisite.dart)
and every preflight check carries one, so the report says who owns each
finding.

---

## 3. The lifecycle

```
testsmith suite run <suite.yaml>
  │
  ├─ 1 RESOLVE ───────── suite syntax · every flow it names · device profile
  │                      · a device to drive                    [no launch]
  │
  ├─ 2 ARRANGE ───────── grant the permissions the suite declares
  │                      (gated on the device being the profile's)
  │
  ├─ 3 PREFLIGHT ─────── application build · device · device profile
  │                      · application installed · permissions
  │                      · network interface · mock API · baselines
  │                      · authentication (deferred)
  │                      ──────────────────────────────────────────────
  │                      blocked ⇒ ENVIRONMENT · exit 2 · nothing launched
  │
  ├─ 4 SUITE SETUP ───── start the fixture server, once
  │
  ├─ 5 PER TEST ──────── reset (only if declared) → grant (only if declared)
  │                      → swap the API scenario (clears the exchange log)
  │                      → launch → verify the profile's handshake half
  │                        (first launch only) → run the flow
  │                      → observe the routes reached → resolve declared
  │                        preconditions → dispose the session
  │                        (which removes the adb reverse it created)
  │
  ├─ 6 AGGREGATE ─────── product verdicts and environment findings, apart
  │
  └─ 7 TEARDOWN ──────── stop the fixture server — always, recorded
                         step by step, failures reported not raised
```

**Arrange before verify, not after.** This was wrong in the first
implementation and hardware found it: preflight read the device, saw the
two location permissions denied, and blocked — over a state step 2 was
about to establish. A suite declares `device.permissions` precisely so the
runner will grant them, so the grant has to come first and the check
becomes a verification that it worked.

**The grant is gated on device identity.** Granting a permission to the
wrong handset is a change nobody asked for, so it happens only once the
device and profile checks pass. Those checks are pure functions, so the
gate costs nothing.

**Preflight runs before the fixture server.** It has to: one of the things
it checks is whether the port is free, which stops being true the moment
the server binds it.

---

## 4. Preflight

A layer that answers one question — *could this machine test anything?* —
before a suite spends minutes finding out it could not.

```bash
testsmith preflight mytest/suites/regression.yaml -d <serial>   # exit 0 or 2
```

Nine checks, each a pure function of facts gathered separately. The
split is the one `doctor` already uses: `flutter_testsmith_cli` reads the device and
the filesystem, `flutter_testsmith_engine` decides what the readings mean. Every
judgement is therefore unit-tested without a handset.

| Check | Blocks when | Class |
|---|---|---|
| application build | `flutter` is not on PATH, or the declared entry point is not in the project | runnerControlled |
| device | nothing attached · the named serial is not there · several attached and none named | devicePrerequisite |
| device profile | adb's model, OS or resolution contradicts the profile | devicePrerequisite |
| application installed | not installed **and** the suite grants or clears before the first launch | runnerControlled |
| permissions | a declared permission is denied, or the manifest never requested it | devicePrerequisite |
| network interface | the device has no active default network | devicePrerequisite |
| mock API | the port is in use · a scenario will not parse · a flow names a state no scenario provides | runnerControlled |
| baselines | never | runnerControlled |
| authentication | never | humanAction |

### Four outcomes, and why there are four

- **satisfied** — checked, and it is there.
- **blocked** — checked, it is not there, and no verdict about the
  application below it could be believed. Carries a remedy, required by
  the constructor rather than by convention: a preflight that reports "no
  network interface" without saying what to do about it is only a slower
  error message.
- **deferred** — not knowable before the application runs. `authentication`
  is always this when something requires it, and the network probe is this
  when the device would not answer. A runner that could not read something
  has learned nothing about it, which is not the same as learning it is
  wrong — the same rule `DeviceFacts` already applies to a device profile.
- **notice** — worth saying, not a reason to stop. A missing baseline is
  this, because E-03 records a first baseline and skips the comparison,
  and turning that into a refusal would change E-03 rather than extend it.

### What a block produces

Every test becomes an environment finding, none is launched, and the
aggregate is ERROR at exit 2 — the code an unevaluable required test has
always produced. `suite.json` and `suite.html` are still written, because
CI wants an answer either way and "we could not test it" is an answer.

```
counts   {"pass": 0, "fail": 0, "error": 5, "skip": 0}
```

That line is from the real run in §13: five tests, zero failures, on a
handset where E-03 would have launched the application five times to find
out the same thing. No test is given an output directory, because none
ran.

---

## 5. Authentication

### What was investigated

Whether the real authentication flow can be a reusable setup operation
*without* bypassing authentication. Three routes were examined and two
were rejected on inspection:

- **A fixture login.** Scenario routes match on **method and path only**,
  so a `/login/consumer` fixture would accept any PIN. That is an
  authentication bypass wearing a test fixture's clothes.
- **Driving login through the flow DSL.** `InputStep.describe()` renders
  `type "<value>" into "<elementId>"` — exactly right for a test step and
  exactly wrong for a credential, which would then be in `result.json`,
  in `report.html` and on the console.
- **A suite `setup:` phase.** Rejected for a structural reason: the setup
  flow must run a *different build* (the UAT build, against the real
  backend) from the tests (the mytest build, against loopback). A suite's
  single `app:` block cannot express two, and making it able to would make
  a suite file two suites.

### What was established, and rejected

Sign-in state **is** readable before launch. `run-as` works on the
debuggable build and `shared_prefs/` can be listed and read. It is
deliberately not used:

- Reading back what the application wrote proves only that something was
  written — the same reasoning E-03 used when it refused to accept a
  storage read as evidence that sign-in had worked.
- It would couple the platform to one application's internal keys.
- It would pull session material into the runner's process, where the
  whole redaction design exists to keep it from being.

Nothing in `DeviceEnvironment` reads application storage. A redaction test
asserts that no preflight artefact so much as names `is_logged_in`,
`SharedPreferences`, `run-as` or a token.

### What E-04 does instead

Authentication is **classified and detected, not automated**. The route
the application lands on is observable for free, from the launch each test
already performs, and the suite declares what an unmet session looks like:

```yaml
preconditions:
  authenticated:
    description: a session obtained through the application's own login flow
    unmetOn: [/login, /onboarding]
    remedy: >
      Sign in on the device through the real application UI …

tests:
  - id: home
    flow: mytest/tests/home.yaml
    requires: [authenticated]
```

`unmetOn` is declared by a person because only a person knows that *this*
application shows `/login` when it holds no session. The runner never
infers it.

**The reclassification is one-way.** It is consulted only for a test that
did **not** pass, and it turns FAIL into ERROR — up the precedence ladder,
never toward PASS. A suite can therefore never go greener by declaring a
precondition. A passing test is never reclassified, whatever route it
ended on; three tests hold that.

### The recommendation

**B — a dedicated setup command**, when there is evidence it is the right
shape. `testsmith auth setup` would launch the UAT build with its own target,
flavour and environment file, drive the real login UI, and take the
credential from an environment variable through a secret-referencing step
whose `describe()` renders the *name* and never the value. It is not built
here because E-04 produced no evidence about its shape, and building a DSL
before that is how a DSL becomes wrong permanently.

Signing in remains **manual and reproducible**, and is the one remaining
human action (§14).

---

## 6. Permissions

Inventory, read off the device (`dumpsys package`):

| Permission | Needed by | How |
|---|---|---|
| `ACCESS_FINE_LOCATION` | every signed-in launch | `device.permissions:`, granted at setup |
| `ACCESS_COARSE_LOCATION` | every signed-in launch | same |
| `POST_NOTIFICATIONS` | `login`, after `clearState` | `grant:` on that test |
| `INTERNET`, `ACCESS_NETWORK_STATE` | the app, always | install-time; auto-granted |
| `CAMERA`, `RECORD_AUDIO`, `READ_MEDIA_IMAGES`, storage, `NFC`, biometrics | declared by the app | never requested by these five flows |

Every permission the five flows need **can** be granted deterministically
through `pm grant`, and all of them now are. None is dismissed: a dialog
is never tapped away, it is prevented from appearing.

The check distinguishes two failures that look alike and are not:

- **denied** — the application declares it and the user has not granted
  it. Remedy: the exact `adb shell pm grant` line, printed.
- **not declared** — the manifest never requests it, so `pm grant` cannot
  grant it. Offering the same remedy would be offering one that does not
  work; the check says so instead.

Both are DEVICE_PREREQUISITE, because the state lives on the handset. The
first is one the runner can establish, and does.

**The ordering interaction is now handled rather than documented.**
`login` declares `reset: clearState`, and `pm clear` revokes the
suite-level grants along with everything else. E-03 could only ask a
person to remember to re-grant them before the next run; the suite now
re-grants at setup.

---

## 7. The network requirement

`connectivity_plus` is an application input. The app calls
`checkConnectivity()` and treats "every result is `none`" as offline,
drawing `no_network_connection_view.dart`. That is a **platform signal**,
not an HTTP request, so no fixture server can answer it — which is why
E-03's offline experiment passed everything up to the point where a Lottie
animation appeared at exactly 96,196 192×192.

The platform therefore says:

```
NETWORK_INTERFACE_REQUIRED
```

and does **not** say `BACKEND_ACCESS_REQUIRED`. The check's remedy carries
the distinction in words: *"No backend has to be reachable: test API
traffic is served on loopback through adb reverse."*

The probe is one line:

```bash
adb shell "dumpsys connectivity | grep -E '^Active default network'"
```

`grep` runs **on the device** deliberately. `dumpsys connectivity` also
prints the SSID, the BSSID, the MAC address and the IP of whatever the
handset is attached to; filtering on the host would mean all of it passing
through the runner's process first. Redacting at capture rather than at
report time is the same rule the SDK follows for network events.

An unreadable probe is `unknown`, never `down` — a probe that failed has
learned nothing, and blocking a run over that would report a fact nobody
established.

**Test API traffic remains fully mocked.** E-04 introduces no new HTTP
call of any kind. The only thing that addresses UAT is the manual
authentication setup, which uses a different build (`main_example.dart`
+ `.env.uat`) from the one under test (`main_mytest.dart` + `.env.mytest`,
`API_BASE_URL = http://127.0.0.1:8080`).

---

## 8. The state lifecycle

Which state belongs to which scope, and who ends it:

| State | Scope | Established | Ended |
|---|---|---|---|
| granted permissions (suite-declared) | **suite** | setup, before preflight | not undone — declared, idempotent, and revoking them would break the next run |
| granted permissions (test-declared `grant:`) | **test** | before that test | not undone, same reason |
| cleared app state (`reset: clearState`) | **test** | before that test, only where declared | not undone — clearing it is the point |
| fixture server | **suite** | once, after preflight | suite teardown, recorded |
| mock scenario + exchange log | **flow** | swapped per flow that names one | replaced by the next swap |
| app process | **test** | one launch per test | session dispose |
| `adb reverse` | **test** | at launch, by the session | **session dispose** — new in E-04 |
| SDK session | **test** | handshake | session dispose |
| baselines | **repository** | committed by a person | never by a run |
| signed-in session | **device** | manually, once | by `login`'s `clearState` |

**Nothing is cleared that the suite did not ask to be cleared.** That was
E-03's rule and it still holds: a runner that wiped the device between
tests would spend its life re-signing-in and would make every test's real
precondition invisible.

**`adb reverse` is now removed.** It was created on every launch and
removed nowhere, so a finished run left the handset forwarding tcp:8080 to
a host that had stopped listening — measured, and then fixed. It is undone
where it was created, in `AppSession`'s shutdown, which is the only place
that knows it exists.

---

## 9. Cleanup

Teardown is a named list, run in a `finally`, recorded step by step:

```json
"cleanup": [
  {"name": "fixture server", "succeeded": true}
]
```

Three properties, each with a test:

- it runs after a failing test as well as a passing one;
- it runs even when preflight blocked the whole suite;
- **a step that fails is recorded, never raised.** Teardown must not throw
  over whatever caused it: when a run fails because the device vanished,
  every cleanup step fails too, and an exception from one of those would
  replace the real cause with a confusing one.

A teardown nobody records is a teardown nobody checks, and its leftovers
turn up later as a run that behaved differently because a previous run had
happened.

---

## 10. Security

**Nothing about the machine reaches an artefact.** A preflight report
carries, per check, exactly `name`, `class`, `outcome`, `detail` and —
when blocking — `remedy`. Asserted as an **allow-list** of keys, because a
deny-list only ever catches the secrets somebody remembered.

Specifically absent, and tested for by literal: the device serial, SSID,
BSSID, MAC prefix, private IP, loopback address, every seeded secret the
E-03 leakage tests already use, and the names `FIGMA_TOKEN`,
`GROQ_API_KEY`, `MYTEST_AUTH_MOBILE`, `MYTEST_AUTH_PIN`.

The device row records the **model**, never the serial — the serial is an
address, not an identity, exactly as E-03 established for baselines.

**The authentication check names no storage key and no credential**, and a
test asserts it: not `is_logged_in`, not `SharedPreferences`, not `run-as`,
not `token`. The route not taken must not be signposted.

### Pre-existing credentials in external_app — a separate item

`external_app` contains hardcoded mobile numbers on **13 lines across 9 test
files** (`test/core/widgets/`, `test/features/auth/`,
`test/features/cart/`, `test/features/payments/`,
`test/features/profile/`), and two keystore-password examples in
`docs/superpowers/plans/`. Counted with
`grep -rlniE "(mobileNumber|primaryMobileNumber)\s*:\s*'[0-9]{6,}'" test/`. They are
fixture-shaped rather than live, and they are **out of scope for E-04**:
they predate it, nothing here reads them, and none of them has been copied
into any new file. They are recorded here as a security-cleanup item for
whoever owns that repository.

The credential used for the manual sign-in lives only in environment
variables outside both repositories, is typed into the application's own
UI by `adb`, and never enters the runner.

---

## 11. CI implications

```bash
testsmith preflight mytest/suites/regression.yaml -d <serial>   # 0 or 2
testsmith suite run mytest/suites/regression.yaml --out results/
```

`testsmith preflight` exists so CI can gate on the environment without paying
for a suite: it answers "could this machine test anything?" in seconds
rather than in eight minutes of launch timeout.

**Exit codes are unchanged**, and eight tests drive the real executable to
hold them there: `64` usage, `2` the run is wrong, `1` the application is
wrong, `0` passed. A blocked environment is `2`, which is what an
unevaluable required test has always produced.

**A blocked run still writes `suite.json` and `suite.html`.** CI wants an
answer either way, and "we could not test it" is an answer; a blocked run
that wrote nothing would be indistinguishable from a run that never
started.

`testsmith preflight` **arranges** the permissions the suite declares before
checking them, so it is not a pure read. That is deliberate: it answers
"can this suite run?", and what the suite arranges for itself is part of
the answer. Two commands that arranged differently would give different
answers to the same question.

Everything E-03 said about CI still holds: a physical Android device is an
environment requirement, there is no emulator path, and there is no cloud
device farm.

---

## 12. What this does to E-03's limitations

E-04 was not allowed to change E-03's semantics, so most of its
limitations still stand. Three move, and it is worth being exact about
how far:

| E-03 limitation | After E-04 |
|---|---|
| 2. the suite cannot establish its own signed-in state | **still true.** What changed is that it now says so - a deferred preflight check, and a PRECONDITION per test - instead of reporting four product failures. §5 recommends the shape that would close it. |
| 10. a system permission dialog stops a run without explaining itself | **narrowed, not closed.** The two known instances (location, notifications) are now prevented rather than explained, because the permissions are granted before they can be asked for. A dialog nobody declared still produces "the app did not start within 8 minutes". |
| 12. the device must have a network interface up | **now detected and named.** `NETWORK_INTERFACE_REQUIRED`, before a test runs, with a remedy that says no backend is needed. |

Everything else in E-03 §12 is untouched: one device per suite, sequential
tests, a relaunch per test, no retries, geometry-only baseline
compatibility, baselines not keyed by authentication state, and the suite
still not printing what the fixture server served.

---

## 13. Real-device evidence

Samsung SM-M127G, Android 13, 720×1600, dpr 1.875 — the handset E-03 was
accepted on, found in the state E-03's own suite leaves it in: signed out
by `login`'s `clearState`, with the location permissions revoked along
with everything else. That starting state was not arranged for this
milestone; it is what the previous milestone's last test produces.

### Preflight, before anything was changed

```
  [ok]    application build      lib/main_mytest.dart
  [ok]    device                 SM_M127G
  [ok]    device profile         samsung-m127g (SM-M127G)
  [ok]    application installed  present on the device
  [BLOCK] permissions            android.permission.ACCESS_FINE_LOCATION,
                                 android.permission.ACCESS_COARSE_LOCATION denied
          -> adb shell pm grant com.example.testapp.alpha …
  [ok]    network interface      an active default network is present
  [ok]    mock API               port 8080, every declared API state resolves
  [ok]    baselines              every photographed screen has one
  [defer] authentication         required by home, orders, profile, journey;
                                 not observable before the application runs …

1 blocking: permissions                                            exit 2
```

### The design error that run found

It blocked on the two permissions **the suite itself declares and was
about to grant**. Verification was running before setup, so every fresh
device would have been refused over a state the very next step would have
established.

The fix is the ordering in §3: grant first, then check — and gate the
grant on the device and profile checks, so a handset that is not the
profile's is never modified. Re-run afterwards: `permissions  2 granted`,
nothing blocking, exit 0.

Worth recording rather than quietly fixing, because it is the second time
in two milestones that running the acceptance gate on hardware found a
rule that was right in the abstract and wrong in its order.

### The network boundary, measured

Wi-Fi and mobile data switched off with `svc wifi disable` / `svc data
disable`. The device then answered:

```
Active default network: none
```

and preflight said:

```
  [BLOCK] network interface  NETWORK_INTERFACE_REQUIRED: the device has no active
                             default network, and the application reads that
                             platform signal directly rather than over HTTP
          -> Turn on Wi-Fi or mobile data. No backend has to be reachable:
             test API traffic is served on loopback through adb reverse.
```

Exit 2. Both radios restored and confirmed back up (`Active default
network: 153`) before anything else ran.

This is the distinction the milestone asked for, demonstrated rather than
asserted: the platform said NETWORK_INTERFACE_REQUIRED and did not say
BACKEND_ACCESS_REQUIRED.

### The suite on a signed-out device

The run that matters, because it is the one E-03 got wrong. Permissions
granted at setup, preflight clear, five tests launched:

```
ERROR home       81.0s   the precondition "authenticated" is not met:
                         the application ended on "/login" …
ERROR orders     79.0s   …
ERROR profile    76.1s   …
ERROR journey    75.8s   …
FAIL  login      43.6s

RESULT: ERROR  (exit 2)
```

| test | verdict | classification | environment | failures |
|---|---|---|---|---:|
| home | error | environment | precondition | 0 |
| orders | error | environment | precondition | 0 |
| profile | error | environment | precondition | 0 |
| journey | error | environment | precondition | 0 |
| **login** | **fail** | **product** | — | **8** |

`counts {pass: 0, fail: 1, error: 4, skip: 0}`.

**Under E-03 this same handset produced four product failures**, naming
four screens that were never on the device's screen. The application was
on `/login` every time, because nobody was signed in. One row changed
meaning and four changed owner.

`login` is the control. It requires the *opposite* precondition, declares
none, and was therefore not reclassified: it is a product FAIL carrying
its eight known design differences, which is exactly what it was before.

### The suite on a signed-in device

The device was signed in by hand through the real UAT build - the one
manual step E-04 deliberately does not automate (§5). Preflight then
granted the two location permissions and verified them, and the suite ran
all five tests:

```
PASS  home     75.2s
PASS  orders   67.8s
PASS  profile  57.6s
PASS  journey  59.6s
FAIL  login    50.9s

RESULT: FAIL  (exit 1)   counts {pass: 4, fail: 1, error: 0, skip: 0}
```

Four signed-in flows green, `home` and `orders` matching their baselines at
0.000% of a million pixels each, and `login` red on its eight known design
differences and nothing else. That is the shape E-03 was accepted on, now
reached through preflight, declared permissions and declared preconditions.

### The four flows this milestone had to correct first

Getting there took a change outside the platform, and it is worth setting
down because the defect was latent in E-03 and surfaced only under E-04's
runs.

Each of `home`, `orders`, `profile` and `journey` opened with a bare
`waitForSettle` immediately after `launchApp`, taking the 10-second
default. That budget is written for the splash. Whether it gets the splash
is a race: the faster the application starts, the likelier the step is
instead asked to settle a dashboard mid-load - six images fading in, a
spinner up, and the two declared Lottie badges not yet started, so the
exact-count rule fails against a screen that has not finished arriving.

Measured on three consecutive runs of the same unchanged suite:

| run | home | orders | profile | journey |
|---|---|---|---|---|
| first | **FAIL** 10 167 ms | PASS | PASS | PASS |
| second (after `home` was corrected) | PASS | PASS | **FAIL** 10 000 ms | PASS |
| third (after all four were corrected) | PASS | PASS | PASS | PASS |

The same step, failing in a different flow each time. E-03's own accepted
run settled it in 1 672 ms *on the splash* - its report records screen `/`
- and only then took two seconds to reach `/home`, which is why the defect
never showed there.

The correction is **four deleted lines**, one per flow, and nothing else:

```diff
   - launchApp
-  - waitForSettle
   - expectScreen:
       id: /home
       timeoutMs: 40000
```

No timeout was added, raised or introduced anywhere. In `orders`,
`profile` and `journey` the step fed nothing at all: `expectScreen`
immediately below already waits 40 seconds for the screen to arrive, and
the settle after *that* covers the screen settling. In `home` it preceded a
`validateScreen` of the splash, and deleting it turned out to make that
step **more** deterministic rather than less - waiting is precisely what
let the application leave the splash before the validation ran.

Verified rather than assumed, on the device, with the settle gone:

```
  › launch the app
  › validate the screen (automatic)
    - api-to-ui: no API-to-UI mappings configured for /
  ✓ validate the screen (automatic)   /  PASS  0 ok, 0 failed, 5 skipped
```

It finds `/` immediately: the handshake's ring buffer carries the first
route, so the screen is known before any frame has rendered. And `/` has no
mappings, no design and no baseline, so the validation photographs nothing
and asserts nothing - `runsVisual` is false, and the quiescence reading is
recorded but never checked. There was nothing for the settle to protect.

**Raising the timeout would have been the wrong fix**, and it is worth
saying why: a longer wait makes it *more* likely the step lands on the
dashboard, which would point `home`'s splash validation at `/home` and
photograph it before the API assertion the flow deliberately puts first.

### The eight Login findings are untouched

Compared field by field on validator, element and message, across every
run this milestone produced:

```
E-03 suite = 8   E-03 standalone = 8
E-04 signed-out = 8   E-04 accepted = 8   E-04 per-test = 8

E-03 suite      == E-04 accepted   : True
E-03 standalone == E-04 accepted   : True
E-04 signed-out == E-04 accepted   : True
E-04 aggregate  == E-04 per-test   : True
```

Three validators, unchanged: `figma-geometry`, `figma-text`,
`figma-typography`. Nothing E-04 added hid, rewrote or softened any of
them.

### Verified alongside

| | |
|---|---|
| `adb reverse` removed | `adb reverse --list` empty after the run. Before E-04 the handset was still holding `tcp:8080` from a run that had finished — found during the investigation, and the reason the removal exists |
| No baseline written | `git status visual_baselines/` empty after every run |
| No retry | 5 launches for 5 tests |
| Cleanup recorded | `"cleanup": [{"name": "fixture server", "succeeded": true}]` |
| App identity read from the handshake | `appVersion 1.0.6`, `buildMode debug` |
| A blocked run still reports | `out/e04-blocked/suite.json` written with `counts.fail = 0` and no test given an output directory, because none ran |
| No serial in `suite.json` | absent, as E-03 established. The preflight section names the model only |
| Three conditions, three exit codes | blocked environment **2**, signed-out device **2**, signed-in device **1** - the run is wrong, the run is wrong, the application is wrong |
| Every executed test has a report | `result.json` + `report.html` under `out/e04-accept/<testId>/` for all five, no orphan directories |

---

## 14. Known limitations

1. **The suite still cannot sign itself in.** It now *says so* — as a
   deferred preflight check and, when the session is absent, as a
   PRECONDITION per test — rather than reporting four failures. The
   sign-in itself is still a sequence of `adb` taps against the real UI.
   §5 recommends the shape that would fix it.
2. **A declared precondition can mis-explain a genuine bug.** If the
   application really did log the user out mid-flow, that test reports
   PRECONDITION rather than FAIL. The direction is conservative — it
   reports "we could not tell" rather than a false pass — but it is a real
   loss of precision, and it exists because `unmetOn` is a human
   declaration rather than a measurement.
3. **The precondition is resolved from the last route only.** A flow that
   passed through `/login` and recovered is not treated as unmet, which is
   right; a flow that ended somewhere the suite did not name is not
   examined further, which may be wrong in a case nobody has met yet.
4. **Baseline availability is a notice, not a blocker.** E-03 records a
   first baseline and skips the comparison, and turning that into a
   refusal would change E-03's behaviour rather than extend it.
5. **The baseline check guesses which screen a flow photographs** from the
   nearest preceding `expectScreen`. Where a flow names none, nothing is
   reported rather than something invented. It can therefore miss a
   missing baseline; it cannot invent one.
6. **Preflight cannot see a system dialog.** E-03's limitation 10 stands:
   if Android holds the foreground for a reason nobody declared, the run
   still reports "the app did not start within 8 minutes". What E-04
   removes is the *known* instance of that — the permission dialogs — not
   the class.
7. **The port check races.** `mock API` binds and releases the port to
   find out whether it is free; something else could take it in the
   interval. The suite's own bind failure is now a classified ERROR rather
   than a crash, so the race degrades to a worse message rather than a
   wrong answer.
8. **`flutter --version` is the slow part of preflight**, costing a few
   seconds. It is the only honest way to answer "can this be built".
9. **Two spellings of the model appear in one report.** The `device` row
   shows what `adb devices -l` said (`SM_M127G`) and the `device profile`
   row what `ro.product.model` said (`SM-M127G`). Both are accurate about
   their own source; neither is normalised, because normalising would hide
   which source said what.
10. **Suite-level grants are never revoked.** The suite leaves the device
    more permissioned than it found it. Revoking them would break the next
    run, and they are declared in a file somebody reviewed — but it is
    state a run leaves behind, and it is named here rather than glossed.
11. **A settle timed from `launchApp` waits for whichever screen is on.**
    Four flows carried one and all four are now corrected (§13), but the
    DSL still cannot say *which* screen a settle is for, so the same
    mistake is available to the next flow somebody writes. Naming the
    screen in the step would close it; that is a DSL change and is not
    here.
12. **`DeviceEnvironment` is Android-only**, as everything below it
    already was.
