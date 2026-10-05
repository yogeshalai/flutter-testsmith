# External application validation

**The question this milestone exists to answer** is at the end, under
"Can this platform be used against a Flutter application that was not
built alongside the testing platform?". Everything before it is the
evidence.

---

## 1. The application

**ExternalApp** — a white-label consumer commerce app, run here as the
`example` brand against its live UAT backend.

| | |
|---|---|
| Repository | private repository, location redacted |
| Commits | 430, multiple authors (`ashishk-vast`, `Aniket Khirsagar`, and others) |
| Dart files | 745 |
| Screens | 34 `*_screen.dart` across 16 features |
| Entry points | 6 (`main.dart`, `main_external_app.dart`, `main_example.dart`, …) |
| Android flavors | 5 |

**How much it differs from the platform's own example** is the point of
choosing it:

| | `examples/ecommerce_app` | ExternalApp |
|---|---|---|
| State | `setState` | Riverpod + hooks |
| Navigation | `Navigator` 1.0, named routes | **go_router**, code-generated, `StatefulShellRoute.indexedStack` |
| Networking | raw `dart:io` `HttpClient` | **dio + retrofit**, three interceptors, a custom `IOHttpClientAdapter` |
| Serialisation | hand-written | freezed + json_serializable |
| Images | `Image.asset` | **flutter_svg**, cached_network_image |
| Interaction | `FilledButton` | mostly `InkWell` / `GestureDetector` |
| Screens | 7 | 34 |

**An honest caveat on the strength of this evidence.** The repository
shares one author with this platform's repository, and some of its
recent commits are contemporaneous. What it is *not* is an application
shaped to suit the tool: its architecture was decided independently, by
a team, before this platform existed, and it had no knowledge of the
test SDK. That is the property the milestone turns on, and it holds. A
genuinely third-party app would be stronger still.

---

## 2. Environment

| | |
|---|---|
| Flutter | 3.44.7 (stable, revision 84fc5cbb22) |
| Dart | 3.12.2 |
| Device | Samsung **SM-M127G**, serial `RZ8T11QETWM` |
| Android | 13 (API 33) |
| Resolution / density | 720x1600, 300 dpi |
| devicePixelRatio | 1.875 |
| Logical viewport | 384 x 805 |
| Build mode | debug, `--flavor example`, `-t lib/main_example.dart` |
| Backend | the application's live UAT backend (host redacted), and the platform's fixture server for §6 |
| Networking library | **dio 5.7** + retrofit 4.7, `IOHttpClientAdapter` |
| Navigation library | **go_router 17.3**, code-generated |

---

## 3. Integration changes

Six files. Every one is listed, and nothing about the application's
architecture was changed to accommodate the tool.

| # | File | Change | Why |
|---|---|---|---|
| 1 | `pubspec.yaml` | `flutter_testsmith: ^0.1.0` — one line, no overrides | *Superseded.* At the time this needed a path dependency plus `dependency_overrides` for both packages, or pub could not resolve at all — finding **E-01**, since fixed. See [E-01_EXTERNAL_SDK_CONSUMPTION.md](E-01_EXTERNAL_SDK_CONSUMPTION.md). |
| 2 | `lib/bootstrap.dart` | `await TestSdk.initialize(...)` before `runApp` | The SDK has to be armed |
| 3 | `lib/bootstrap.dart` | an extended `retentionPolicy` | The default keeps only Flutter's own widget types; this app's icons, images and tap targets were invisible — finding **E-08** |
| 4 | `lib/core/router/app_router.dart` | `observers: [TestSdk.navigatorObserver]` on the `GoRouter` | `MaterialApp.router` takes no `navigatorObservers` |
| 5 | `lib/core/widgets/app_bottom_menu.dart` | `TestId` wrapper per tab, id derived from the label already declared | Five navigation ids, no constructor changed |
| 6 | `lib/features/profile/**` | `TestKey` on the display name, `TestId` on two conditional widgets | Three semantic ids on one screen |

Plus four directories of **test configuration** that the platform
requires to live inside the application directory (`mappings/`,
`mock_api/`, `mytest/tests/`, `visual_baselines/`) — finding **E-09**.

**Reverted after measurement**, and not part of the integration: a
one-line font-size change used to seed a visual defect (§8), and
pointing `API_BASE_URL` at the fixture server for §6.

**Tried and reverted** because the evidence said they were not needed: a
`screenIdResolver` hook on the SDK facade, and a go_router-aware
resolver in the app. Once the platform refused unstable route names, the
default resolver was correct for every real screen.

---

## 4. Baseline compatibility

`testsmith doctor`, `devices`, `smoke` and `inspect` all run against the
external application. The smoke run, verbatim:

```
  session          9eecbd61-9fa5-4a52-aed6-90fdf2e74a5f
  protocol         1.0
  capabilities     navigation, uiTree, network, screenshot
  app version      1.0.6
  build mode       debug
  dpr at attach    1.875
  dpr settled      1.875

  recovered from ring buffer   2
  arrived on live stream       9
  duplicates discarded         2
  distinct events              9
  history complete             yes

  ui tree nodes                4
  elements walked              245

  API exchanges by screen
    /   GET /mobileversion/Consumer/android  500
        GET /appconfig                       200
        GET /appmaintenance/Consumer/Android 200

PASS: channel verified end to end.
```

Note the **500**: a real failure from the live backend, captured and
attributed, on the first run.

---

## 5. Navigation validation

| Kind | Present? | Result |
|---|---|---|
| Imperative (`context.push`) | yes | **works** — `/profile/edit` and friends report their path |
| Declarative (go_router redirect) | yes | **works** — `/` → `/home` via the redirect guard is observed |
| Nested / shell (`StatefulShellRoute.indexedStack`) | yes | **partial** — tab screens report correctly; the shell's own route cannot be named (**E-05**) |
| Tabs | yes | **works** — `nav.orders` → `/orders`, `nav.profile` → `/profile` |
| Back | yes | **works** — `didPop` observed |

Screens observed, in order, on a real run:

```
/ -> <unnamed:_PageBasedMaterialPageRoute<void>> -> /home
```

**Missing events:** none observed.
**Duplicate events:** 2 duplicates discarded by the ring-buffer/live
overlap, as designed.
**Incorrect screen ids:** one, and it is **E-05** below.
**Attribution problems:** one, and it is the most serious finding in
this document — §11, STOP-1.

---

## 6. UI inspection

Measured on `/orders`: **1017 elements walked, 48 retained (95.3%
filtered)**.

| Element kind | Represented? | Note |
|---|---|---|
| Text | yes | 9 nodes, with resolved fontSize / weight / family / colour |
| Image | yes | `Image` nodes present |
| Button | **only after extending the policy** | this app uses `InkWell`; the default keeps only `*Button` |
| TextField | yes | on the login screen |
| List | yes | `ListView` ×2 |
| Scroll containers | yes | `Scrollable` ×2 |
| Semantics | yes | e.g. `Semantics [Open voice assistant]` |
| enabled | **partly** | see **E-07** |
| visible | yes | |
| bounds | yes | logical pixels, correct against the 384pt viewport |
| TestKey / TestId | yes | both resolve |
| Third-party widgets | **only after extending the policy** | `SvgPicture`, `CachedNetworkImage` — **E-08** |

**D-04 (ListTile `enabled`)** — not reproduced. This app does not use
`ListTile` for its tap targets; it uses `InkWell`, which produced the
same class of problem one level up (**E-07**).

**D-13 (sensitive UI-tree exposure)** — held. No obscured field was
reachable without signing out, so it was not exercised *on this app*;
the platform's permanent regression test covers it and passed.

---

## 7. API capture

The application uses **dio with a custom `IOHttpClientAdapter`** —
which this platform's own risk register (R9) listed as **unsupported**.

**It is captured.** The custom adapter builds its client with
`HttpClient()`, a factory that consults `HttpOverrides.current`, so the
SDK's override wraps it. Measured, not reasoned about.

| | Result |
|---|---|
| Captured requests | yes — 8 distinct endpoints across four screens |
| Captured responses | yes — including a real `500` and real `404`s |
| Correlation (request↔response) | yes |
| Screen attribution | **works mechanically, and is often not useful** — see STOP-1 |
| Redaction | yes — §10 |
| Other hosts | yes — a third-party geocoding call to a different host was captured |

Endpoints captured: `/appconfig`, `/mobileversion/Consumer/android`,
`/appmaintenance/Consumer/Android`, `/api/profile/me`,
`/api/dashboard/summary`, `/api/billing/{id}`,
`/api/requests/{id}`,
`/v4beta/geocode/location/{lat},{lng}`.

**Not tested, and therefore not claimed:** web/`fetch`, gRPC,
WebSockets, `package:http` without an IO adapter, and any request made
on the native side by a plugin. The app's Firebase traffic falls in that
last category and was not captured.

---

## 8. API → UI validation

**Partial, and the shortfall is a platform limitation rather than an
application problem.**

What **was** established, on trees captured from this app on the device
(`packages/flutter_testsmith_engine/test/external_app_tree_test.dart`, 10 tests):

| Case | Result |
|---|---|
| Normal value matches | **PASS** |
| Seeded mismatch (`"My Orders"` vs `Orders`) | **caught**, with raw / transformed / UI values in the evidence |
| Missing field | **caught** — "has no field" |
| Reading `text` through a `TestId` wrapper | **works** (after E-07) |
| Reading `enabled` through a `TestId` wrapper | **works** (after E-07) |
| Declared endpoint the screen never called | **error**, naming what it *did* call |
| Rule asserting `enabled` through a wrapper | **PASS** (failed before E-07) |

On-device, `ui-presence profile.display_name` **passed** against the
real screen, so the semantic ids and the capture path are sound.

What was **not** established: a complete on-device API→UI comparison on
any screen of this application. Two independent structural facts
prevented it, both recorded as STOP items in §11:

1. the data a screen renders is usually fetched on an **earlier** screen
   and cached (STOP-1);
2. most screens **never settle**, so `validateScreen` cannot run after
   the data arrives (STOP-2).

A mapping file was written (`mappings/profile.yaml`) covering a normal
value, a conditional field, null, missing field and an error state, with
eight fixtures for them (`mock_api/scenarios/`). They are committed and
will work the moment either STOP item is resolved.

**AI took no part in any verdict here**, and there is no code path by
which it could.

---

## 9. Figma validation

**NOT PERFORMED.** No Figma specification was available at the time of
writing.

What is needed to perform it is small and specific: for each screen, a
**file key** and a **node id**, plus a token with read access — the
three values `testsmith figma pull` takes. The two screens worth doing
first are **Login** (always reachable, fully deterministic — the control
case) and the **Dashboard** (the complex screen).

No specification was hand-authored to fill the gap, because a
hand-authored spec measured from the implementation proves only that the
implementation matches itself. The Figma validators are exercised
against real pulled designs in the platform's own
[figma defect matrix](evidence/figma_defect_matrix.md); what remains
untested is whether a *second team's* Figma file normalises usefully.

---

## 10. Visual validation

Run on `/profile`, which is one of the few screens in this application
that settles.

**Unchanged screen, repeated:**

| Run | Differing | SSIM |
|---|---|---|
| 1 | *(baseline recorded)* | — |
| 2 | **0.000%** of 1,076,400 px | **1.0000** |
| 3 | **0.000%** | **1.0000** |

**False positives: 0 of 2.** On a third-party app, on a real device,
against a live-shaped backend.

**Seeded visual defect** — the display name's font size raised by 8pt:

| Run | Whole screen | Element |
|---|---|---|
| 1 | 0.202% (tolerance 0.200%) | `profile.display_name` **28.493%** of its own area |
| 2 | 0.202% | **28.493%** |

**Detection: 2 of 2, identical to three decimal places.** The
whole-screen number only just crosses its tolerance; the per-element
gate is what makes the finding unambiguous — and it names the element,
which is the same lesson Phase 12 measured on the example app.

**Capture-path handling:** correct. The baseline records
`deviceScreencap`, and the element regions named belong only to the
topmost route — the D-12 fix, exercised here on a real
`StatefulShellRoute`.

**No claim of pixel-perfect Figma equality is made anywhere.**

---

## 11. Findings

Classified as the brief requires. **Ten found; eight fixed.**

### BUG — fixed

| # | Finding | Evidence |
|---|---|---|
| **E-01** | `flutter_testsmith` cannot be added to any app outside its own monorepo. `flutter_testsmith_protocol` is unpublished, so pub looks for it on pub.dev and version solving fails outright. | *"Because every version of flutter_testsmith from path depends on flutter_testsmith_protocol any which doesn't exist … flutter_testsmith from path is forbidden."* Worked around with `dependency_overrides` at the time. **Now fixed:** the root cause is that pub resolves a fetched package's own dependencies from the *default* repository rather than the one it came from, so `flutter_testsmith` and `flutter_testsmith_protocol` are served from a private package repository and the application declares `flutter_testsmith: ^0.1.0` and nothing else — see [E-01_EXTERNAL_SDK_CONSUMPTION.md](E-01_EXTERNAL_SDK_CONSUMPTION.md). |
| **E-02** | The runner could not launch the app at all: `flutter run` was hardcoded with no `--target` and no `--flavor`. | This app has 6 entry points and 5 flavors. Added `-t/--target` and `--flavor` to `run`, `smoke` and `inspect`. |
| **E-03** | Teardown force-stopped `com.example.ecommerce_app` — the platform's own example. `am force-stop` succeeds for a package that is not installed, so it failed **silently**, left the app running, and broke the *next* run. | Observed as a leftover process on the device. `smoke` now takes `--app-id`. |
| **E-04** | `connect()` scanned the isolate list once and gave up. This app initialises dotenv, preferences and Firebase before `TestSdk.initialize`, so it lost the race and reported "the test SDK is not armed". | Reproduced twice. Now waits, as everything else in the platform does. |
| **E-05** | go_router names the route it builds for a `StatefulShellRoute` with an **object hash**. The default resolver trusted it as a screen id. | Two consecutive runs reported `100338058` and then `720295915`. An id that *looks* stable would bind mappings and baselines to nothing on the next run. A numeric name is now refused, falling back to the loud `<unnamed:…>` marker. |
| **E-06** | `inspect` gave a `--tap` element 10s, measured from a fixed 3s sleep after launch. | This app's splash takes ~13s; `inspect` reported "the captured tree has no test ids at all", which describes the splash perfectly and explains nothing. Widened to 30s. |
| **E-07** | `readProperty` read only the node itself, so a semantic id on a wrapper reported `enabled: null` while the `InkWell` two levels down reported `true`. A rule asserting on it failed against a **correct** screen. | Measured: `TestId #nav.orders enabled=None` → `InkWell enabled=True`. Now falls through to an unambiguous descendant, mirroring how the design comparison already finds the text inside a button. |
| **E-10** | `api:` has been in the mappings format since Phase 4 — parsed, and then ignored. The validator compared against whichever response arrived first. | The first exchange on `/profile` was a **third-party geocoding call to another host**, and the profile's mappings were compared against it. Fixed; a declared endpoint now selects the exchange, and an endpoint the screen never called is an error that names what it did call. |
| **D-12** | *(carried from Phase 12, fixed here as Step 9 required)* Per-element visual regions included elements from routes underneath the current screen. | Probed: capturing after a push returns **both** routes' test ids, with real bounds and `visible: true`. Nodes now carry a route index and the visual validator measures only the topmost route. Regression tests on both sides, plus the real go_router tree. |

### UNSUPPORTED CASE

| # | Finding |
|---|---|
| **E-08** | The retention policy knows only Flutter's own widget types. This app's icons (`SvgPicture`), remote images (`CachedNetworkImage`) and tap targets (`InkWell`) were **invisible** to the tree. Extending it took the capture from 26 to 48 nodes and made `enabled` available at all. The policy *is* an extension point, so this is configuration rather than a defect — but the default is wrong for any real app, and `UiRetentionPolicy.defaults()` is **not composable**: the whole ~30-type list has to be restated to add one. |

### DOCUMENTATION GAP

| # | Finding |
|---|---|
| **E-09** | The platform requires its configuration — `mappings/`, `mock_api/`, `visual_baselines/` — to live **inside the application directory**. A team may not want test-platform config committed to the application repository, and nothing says so or offers an alternative. |

### ARCHITECTURAL LIMITATION — STOP AND REPORT

Two findings cannot be fixed without an architectural decision. Per the
brief, neither was acted on.

---

#### STOP-1 — The screen that fetches is not the screen that renders

> **Resolved.** Implemented as an explicit `usesResponseFrom:`
> declaration — see [STOP_1_DATA_PROVENANCE.md](STOP_1_DATA_PROVENANCE.md).
> The ExternalApp `/profile` case below now reports
> `PASS 4 ok, 0 failed`, with the source screen `/` different from the
> rendered screen `/profile`. The recommendation made here (option 2,
> an explicit declaration) is what was built.

**Problem.** API→UI validation assumes the response a screen displays
was captured *while that screen was current*. In this application it
usually was not: providers are `keepAlive`, data is fetched during
splash or on an earlier tab, and the rendering screen makes no request
at all.

**Evidence.** `/profile` renders the consumer's name. The run reported:

```
ERROR api-to-ui — the mappings name "GET /api/profile/me",
which this screen did not call. It called:
GET /v4beta/geocode/location/18.5448976,73.7858687.
```

Re-selecting the tab to force a refresh did not change it. Across four
screens, **no screen captured the response it rendered**.

**Current architecture.** `SessionCorrelator` attributes an exchange to
the screen current when the request *started*. `ValidationContext`
exposes only that screen's exchanges. One screen, one session, one set
of exchanges.

**Proposed change.** Let a screen validate against a response captured
earlier in the session — for example, `ValidationContext` falling back
to the most recent completed exchange matching the declared endpoint
*anywhere in the run*, with the report stating plainly which screen it
was captured on.

**Alternatives.**
1. Require the application to re-fetch on screen entry — pushes the
   platform's constraint into the application's architecture, which this
   milestone exists to avoid.
2. Add an explicit `usesResponseFrom:` to the mappings file — honest and
   verbose; the team states where the data came from.
3. Do nothing, and document that API→UI validation only works on screens
   that fetch their own data.

**Recommendation.** Option 2, then 1 as a fallback. A session-wide
fallback (the "proposed change") risks silently comparing against a
stale response from minutes earlier, which is exactly the class of
quiet wrongness this platform is built to avoid. An explicit
declaration keeps the human in the loop and the report auditable.

---

#### STOP-2 — Screens that never settle

**Problem.** `waitForSettle` requires no frames for a quiet period and
no running animations. Screens in this application animate
continuously, so it never returns and `validateScreen` can never run
after the data arrives.

**Evidence.**

```
/home    the screen did not settle within 10s.
         Still waiting on: frames still rendering; 2 animations running
/orders  the screen did not settle within 10s.
         Still waiting on: frames still rendering; 1 animation running
```

`/profile` does settle, which is why §8 and §10 could use it.

Phase 12's own recommendation predicted this: *"Does `waitForSettle`
return on a screen with a shimmer placeholder or a looping animation?
Nothing here has one."* It does not.

**Current architecture.** `SettleState` gates on
`transientCallbackCount` — Flutter's count of running animations —
plus a frame-quiet period and in-flight requests. The gate exists to
stop a tree or screenshot being captured mid-transition, which is what
makes visual comparison stable at all.

**Proposed change.** Separate "the screen has stopped changing" from
"the screen has finished loading". A validation that needs only the
tree could proceed while a decorative animation runs; a visual
comparison could not.

**Alternatives.**
1. A per-flow `waitForSettle: { ignoreAnimations: true }`. Simple, and
   it makes visual comparison quietly flaky for anyone who uses it.
2. Ignore animations *outside* a named region, so a carousel can be
   excluded the way a status bar already is.
3. Use `expectElement` to wait for a rendered value instead of settling
   — already possible today, and the workaround used in §8.
4. Do nothing, and document that continuously-animating screens support
   structural validation but not visual comparison.

**Recommendation.** Option 3 for now — it needs no change and already
works — with option 2 as the eventual answer, because it preserves the
guarantee that makes settle worth having. Option 1 should be refused:
a flag whose cost is silent visual flakiness is exactly the kind of
convenience that gets a check switched off.

> **Since resolved**, as its own milestone, along option 2's lines. The
> diagnosis above is **wrong**: the dashboard runs no banner carousel.
> Three of the four animations are loading indicators that stop when the
> data arrives; the perpetual pair are looping discount badges. The
> 10-second wait expired during a cold start that takes 8.3s on its own,
> and a bare count could not tell that apart from a screen that never
> settles. `/home` and `/orders` are now visually validatable - 5 of 5
> and 3 of 3 exact matches on device. See
> [STOP_2_QUIESCENCE.md](STOP_2_QUIESCENCE.md).

---

## 12. Security

All assertions made against the application's **real** JWT, not a seeded
value.

| Check | Result |
|---|---|
| The app really sends a bearer token on these calls | **yes** — `AuthInterceptor` attaches `Authorization: Bearer $token` to everything except seven auth endpoints; `/appconfig`, `/mobileversion` and `/appmaintenance` are not among them |
| JWT in emitted events | **absent** — `redaction verified: "eyJ" appears nowhere in 9 events` |
| JWT in `result.json` | **absent** (0 occurrences) |
| JWT in `report.html` | **absent** (0) |
| `Bearer` / `Authorization` values in artefacts | **absent** (0) |
| JWT in captured UI trees | **absent** (0 in both captured trees) |
| D-13 obscured-field masking | **held** — permanent regression test passes; not exercised on this app, because no obscured field is reachable without signing out |

The non-vacuity matters and is established: the token is genuinely on
the wire for the three requests the assertion covers.

---

## 13. Test counts

| Package | Before this milestone | Now |
|---|---|---|
| `flutter_testsmith_protocol` | 96 | **96** |
| `flutter_testsmith_engine` | 440 | **472** |
| `flutter_testsmith_cli` | 82 | **82** |
| `figma_client` | 37 | **37** |
| `ai_client` | 20 | **20** |
| `flutter_testsmith` | 202 | **213** |
| `examples/ecommerce_app` | 84 | **84** |
| **Total** | **961** | **1,004, all passing** |

`dart analyze --fatal-infos`: no issues.
`scripts/check_dependencies.dart`: all rules hold.

On hardware: 16 runs against the external application (smoke ×2,
inspect ×5, flows ×9).

---

## Can this platform be used against a Flutter application that was not built alongside the testing platform?

**Yes, with two material caveats, and not yet without help from the
platform team.**

**What works, on a real app on real hardware, with no architectural
change to the application:** launch, attach, handshake, navigation
tracking across imperative, declarative, shell and tab navigation, UI
tree capture on a 1017-element screen, tap by semantic id, API capture
through dio's custom adapter — including a third-party host — screenshot
capture, visual regression with **zero false positives and 2-of-2
detection of a seeded defect**, and redaction of a real production JWT
from every artefact.

**What it cost:** six files touched and four config directories added.
Ten defects surfaced, eight fixed. **Five of those defects — E-01
through E-04 — blocked the tool from running at all**, and every one of
them existed because the platform had only ever been pointed at an app
written beside it. That is the honest headline: the platform worked, and
nothing about it worked on the first try.

**What does not work yet:** a complete API→UI validation on this
application's screens, for the two architectural reasons in §11. Those
are not defects to be patched; they are assumptions the platform makes
about how applications fetch and render data, and this application does
not hold them. Until STOP-1 is resolved, the platform's central
claim — *validate the whole chain from API response to UI field* —
cannot be demonstrated on an app that caches its data.

**Is it production-ready?** No, and less so than a first reading of §10
suggests. Structural validation, visual regression and security hold up
well on a stranger's code. The API→UI chain — the capability this
platform exists for — could not be completed on a single screen of the
first real application it met.

---

## Recommended next priority

**Resolve STOP-1: let a screen validate against the response that
produced its data, wherever it was captured.**

Not because it is the largest piece of work, but because it is the only
one blocking the platform's reason to exist. Everything else measured in
this document either works or has a workaround; this does not, and no
amount of instrumenting an application fixes it from the outside.

Concretely, in order:

1. **STOP-1**, via an explicit `usesResponseFrom:` in the mappings file
   (§11, recommendation 2). Small, auditable, no silent staleness.
2. **Publish `flutter_testsmith_protocol` and `flutter_testsmith`**, or vendor them into a
   single publishable package. E-01 makes adoption by any team outside
   this repository start with a workaround, which is a poor first
   impression and a real barrier.
3. **A composable retention policy** — `UiRetentionPolicy.defaults().plus({...})`
   — and a default that includes `InkWell`, `GestureDetector` and the
   common third-party image widgets. E-08 cost this integration an
   invisible tree until it was diagnosed.
4. **STOP-2**, via option 2 (animation-ignore regions).

Explicitly **not** next, and unchanged from Phase 12: cloud backend,
dashboard, autonomous exploratory AI, device farm, multi-user, and a
release-mode WebSocket transport.

Two things are worth doing alongside, cheaply: obtain the Figma file key
and node id for the Login and Dashboard screens so §9 can be completed,
and run this same exercise against an application with **no shared
authorship at all**, which is the one caveat this milestone could not
remove.
