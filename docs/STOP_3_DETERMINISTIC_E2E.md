# STOP-3: baselines that were photographs of a backend

**Status:** implemented.
**Scope:** deterministic API data, API assertions inside a UI flow, and
the reporting that ties the two together. No Figma, no autonomous AI, no
device farm.

---

## The original problem

STOP-2 ended with `/home` matching its baseline 5 times out of 5 and
`/orders` 3 out of 3. Both numbers were true and neither was worth much,
because of one line in that document's limitations:

> The `/home` and `/orders` baselines were recorded against the live UAT
> backend, not a fixture, because the committed dashboard scenario is an
> empty stub. They will drift when that backend's data changes.

A visual baseline is a claim that a screen looks a certain way **given a
response**. Recorded against live data it is a photograph of whatever the
backend held that morning: it would have failed the day an outlet closed
or a price moved, the failure would have looked exactly like a real
regression, and the natural reaction — widen the tolerance until it stops
— is how a visual check dies.

The committed fixture said this, and parsed cleanly into an empty screen:

```json
"GET /api/dashboard/summary": {
  "status": 200,
  "body": { "data": { "businesses": [], "banners": [] } }
}
```

`DashboardData.fromJson` reads `banner`, `outletsNearYou`,
`favouriteOutlets` and three more keys at the **top level** of the
response. Nothing it reads was there. The stub was not wrong in a way any
test could see; it was a 200 that rendered nothing.

## What replaced it

```
mock_api/scenarios/
  default.json               startup, profile, and the empty states
  dashboard_populated.json   ← /home        inherits default
  orders_populated.json      ← /orders      inherits dashboard_populated
```

`dashboard_populated` holds three open outlets, **two of them carrying an
active discount offer**, one closed outlet, and two banners. Every id,
name, price, rating, distance and image URL is fixed in the file.
`orders_populated` adds three past orders with fixed ids, statuses,
service modes, instants and line items, and inherits the dashboard — so
one launch can walk `/home` and then `/orders` without the API state
changing underneath it.

Both are deltas against `default`, which is the mechanism that already
existed. No second mocking framework was introduced.

### Pictures, too

An outlet card draws a remote image, and a screen drawing images from
somebody else's CDN cannot be photographed deterministically: the bytes
are outside this repository's control and the fade-in is timed by their
network. The fixture server could not answer with a picture — `body` goes
through `jsonEncode` and `rawBody` is a Dart string, so neither can carry
a PNG intact.

One key closes it:

```json
"GET /fixtures/outlet-biryani.png": {
  "status": 200,
  "headers": { "content-type": "image/png" },
  "bodyBase64": "iVBORw0KGgoAAAANSUhEUg..."
}
```

`bodyBase64` is decoded **at parse time**, so a corrupt fixture fails
when the file is read rather than reaching the screen as a broken-image
placeholder that photographs perfectly well and explains nothing. No
content type is guessed: a scenario that sends bytes says what they are.

## Reaching the fixture server at all

This was the undocumented blocker. The application selects its
environment by *which entry point you launch* — `EnvConfig.apiBaseUrl`
reads `API_BASE_URL` from a bundled `.env.*` asset, and there is no
`--dart-define` for it. Aiming the app at a fixture server therefore
meant editing `.env.uat`, a file five brands and every real build read,
and remembering to put it back. That was done and reverted by hand during
the external-application milestone.

The replacement is a **test-only entry point**, not a production
override:

| File | |
|---|---|
| `lib/main_mytest.dart` | two lines; calls the same `bootstrap` |
| `assets/brands/example/env/.env.mytest` | `API_BASE_URL=http://127.0.0.1:8080`, everything else copied |
| `pubspec.yaml` | one asset line |

Nothing ships it. No flavor, store listing or release pipeline names
`main_mytest.dart`, and every production entry point is byte-identical to
what it was. The loopback address is what `adb reverse tcp:8080` maps
into the device; a physical device has no equivalent of the emulator's
`10.0.2.2`.

## Narrowing the exception

STOP-2 recorded this, and it is the most important thing this milestone
changed:

> A declaration is only as tight as the id it names. `home.body` is the
> dashboard's whole scroll view, so a second `Lottie` added anywhere
> inside it would be permitted without anyone noticing.

Three narrowings now, each closing a hole the others cannot:

```yaml
quiescence:
  allow:
    - element: home.outlets_near_you
      widget: Lottie
      count: 2
      reason: the discount badge on each of the two outlet cards running an offer
```

| Key | Closes |
|---|---|
| `element: home.outlets_near_you` | the **place**. Each outlet rail carries its own id now, so a Lottie in the banner carousel or the refer-and-earn card is still unexpected. `home.body` was the whole scroll view. |
| `widget: Lottie` | the **kind**. A shimmer on the same rail still blocks. |
| `count: 2` | the **number**. A third Lottie on that rail blocks, which neither of the others can catch. |

`count:` is the new key, and it is only defensible because of everything
above it in this document. A screen fed by live data does not know how
many badges it will draw, which is exactly why STOP-2 said an unused
declaration must not be fatal — "erroring would make the run depend on
how much data a fixture happens to hold". Now the fixture *is* the data,
so the number is knowable, and the flow asserts it at the API before
quiescence relies on it:

```yaml
- expectApi:
    endpoint: GET /api/dashboard/summary
    status: 200
    expect:
      - path: outletsNearYou.outletsNearYouData
        count: 3
```

A miscount does not permit the surplus and block the rest. Nothing says
*which* of three badges is the newcomer, so a count that does not hold
permits **none** of them:

```
"home.outlets_near_you" declares 3 Lottie animations and 2 are running. A
declared count is exact, so none of them is permitted until either the
screen or the declaration changes
```

Two parse errors keep it honest: `count: 0` is refused (leaving the
declaration out is what "none of these may run" already means, and one
idea should not have two spellings), and so is anything that is not a
whole number of one or more.

**Integration cost in the application: one more `TestId` and one
parameter on a private widget.** `_OutletListSection` takes a `testId`
and wraps itself in it. No application logic changed.

## Asserting on the API inside a UI flow

Every check the platform had was a statement about a screen. A run could
therefore go green while the application rendered a plausible screen from
a cached response, a 304, or the wrong endpoint entirely — which is
exactly what STOP-1 found on a real profile screen. A screen rendered
from a **failed** request photographs perfectly well.

`expectApi` is a step rather than a flag on `validateScreen`, because an
assertion about the API is only meaningful at a point in time:

```
tap "nav.orders"
  → expect GET /api/requests/* to have answered 200
  → expect to be on "/orders"
  → wait for settle
  → photograph
```

| Key | |
|---|---|
| `endpoint` | `METHOD /path`; a segment may be `*` |
| `status` | **required** — a step that says nothing about the answer passes against a 500 |
| `occurrence` | `only` (default, refuses to choose), `first`, `last` |
| `expect` | a list of `path` plus exactly one of `equals`, `count`, `present` |

It reads the exchange the **application** made, through the SDK's
capture — not the fixture server's log, which would prove only that the
fixture server works. A response the app served from its own cache
appears in one and not the other, and that difference is the whole point.

`present:` exists so a token can be asserted without being written down.
The outcome carries the endpoint, the status and the failures, and
deliberately **no response body**: a report is a file people paste into
tickets.

### One flow, both halves interleaved

`mytest/tests/journey.yaml` is the shape this was heading towards -
UI action, API assertion, UI action, API assertion, quiescence,
photograph - measured on the device:

```
API
✓ GET /api/dashboard/summary  200
✓ GET /api/requests/6a50c57c5580d50012f58627  200

UI
✓ expect to be on "/home"
✓ validate the screen (visual:off, rest automatic)
✓ tap "nav.orders"
✓ expect to be on "/orders"
✓ validate the screen (visual, rest automatic)

QUIESCENCE
✓ /home    2 ticking, 2 permitted, 0 unexpected
✓ /orders  nothing was ticking

VISUAL
✓ "/orders" matches the baseline: 0.000% of 1076400 pixels differ, ssim 1.0000

RESULT: PASS
```

A screen is photographed only after the response behind it has been
named and checked, so a green picture can no longer mean "the app
rendered something plausible from a cached response".

## What the report says now

```
E2E: home
────────────────────────────────────────────────

API
✓ GET /api/dashboard/summary  200

UI
✓ launch the app
✓ expect to be on "/home"
✓ wait for the screen to settle
✓ validate the screen (visual, rest automatic)

QUIESCENCE
✓ /: nothing was ticking
✓ /home
    ticking animations: 2
    permitted: 2
    unexpected: 0
    permitted: Lottie in "home.outlets_near_you" at 42,790 33x33 - the discount badge on each of the two outlet cards running an offer
    permitted: Lottie in "home.outlets_near_you" at 42,1197 33x33 - the discount badge on each of the two outlet cards running an offer

VISUAL
✓ "/home" matches the baseline: 0.000% of 1072742 pixels differ, ssim 1.0000

RESULT: PASS
```

Four sections, always in that order, each answering one layer's question.
A section with nothing in it **says so** rather than being omitted: "no
API assertions were made" and "every API assertion passed" are different
facts, and a missing section reads as the second.

A blocked comparison reads `BLOCKED`, never `✗`. An undeclared animation
means the tool could not take an honest picture; it is not a claim that
the screen is wrong.

## Device evidence

Samsung **SM-M127G**, serial `RZ8T11QETWM`, Android 13, 720x1600 at
1.875 dpr, app 1.0.6 debug, flavor `example`, entry point
`lib/main_mytest.dart`. **Fixture server only — the UAT backend was not
reachable from any of these runs.**

### The positive suite

| Screen | Scenario | Runs | Exact matches | Pixels differing | SSIM | Ticking | Permitted | Unexpected |
|---|---|---|---|---|---|---|---|---|
| `/home` | `dashboard_populated` | **5** | **5** | 0.000% of 1,072,742 | 1.0000 | 2 | 2 | 0 |
| `/orders` | `orders_populated` | **5** | **5** | 0.000% of 1,076,400 | 1.0000 | 0 | 0 | 0 |
| `/profile` | `default` | 1 | 1 | 0.000% of 1,076,400 | 1.0000 | 0 | 0 | 0 |

`/home` compares 3,658 fewer pixels than the full screen. That is the two
badge boxes leaving the comparison, which is the exclusion working: the
declaration says what is permitted, the inventory says what to exclude.

`/profile` is untouched and still reports **5 ok, 0 failed** — including
STOP-1 provenance and the effective-text resolution.

### Narrowing, demonstrated by breaking it

Three runs, in order, on the device.

**1. The widget type deliberately wrong** (`widget: Shimmer`):

```
✗ wait for the screen to settle
    the screen did not settle within 30s. Still waiting on:
    "home.outlets_near_you" declares 2 Shimmer animations and 0 are running.
    A declared count is exact, so none of them is permitted until either the
    screen or the declaration changes; 2 unexpected animations running:
    Lottie in "home.outlets_near_you" at 42,790 33x33,
    Lottie in "home.outlets_near_you" at 42,1197 33x33.

RESULT: FAIL
```

**2. The count deliberately wrong** (`count: 3`, two badges running) —
this is the case `widget:` alone cannot catch, and the one that stands in
for an unrelated third Lottie appearing on the rail:

```
"home.outlets_near_you" declares 3 Lottie animations and 2 are running.
A declared count is exact, so none of them is permitted ...
2 unexpected animations running: Lottie at 42,790 33x33, Lottie at 42,1197 33x33

RESULT: FAIL
```

**3. Restored:**

```
✓ "/home" matches the baseline: 0.000% of 1072742 pixels differ, ssim 1.0000
RESULT: PASS
```

STOP-2 could not do this: the badges were built from live data and ticked
only intermittently, so a deliberately narrowed declaration "could not be
made to reproduce in three attempts". With the fixture they tick on every
run. **No broken configuration is committed.**

### Negative tests

| # | Case | Arranged by | Result |
|---|---|---|---|
| A | Unexpected animation | the mismatch above | **FAIL**, naming both Lotties with their bounds |
| B | Loading never settles | `dashboard_stalled` (600s delay) | **FAIL** — `CircularProgressIndicator at 174,367 36x36 (no semantic id)`, plus `2 requests still in flight`. No picture taken |
| C | API failure | `dashboard_500` | **FAIL** at the API row: `answered 500, expected 200`. The screen still painted |
| D | API data changed | `dashboard_changed` | **FAIL twice over** — see below |
| E | Screenshot instability | `dashboard_late_images` | **did not reproduce on device** — see below |

**D is worth two lines**, because it failed at two different layers and
both matter. Run through the normal `/home` flow it stops at the API:

```
✗ "outletsNearYou.outletsNearYouData.0.businessName" is
  "Example Restaurant, Baner Annexe", expected "Example Restaurant, Baner"
```

That is the right place and the fastest feedback — and it means no
photograph is ever taken, so it proves nothing about the visual layer.
`mytest/tests/negative/home_changed.yaml` asserts only the status, lets
the changed data reach the screen, and compares against the unchanged
picture:

```
QUIESCENCE  ✓ 2 ticking, 2 permitted, 0 unexpected
VISUAL      ✗ "/home" 0.237% of pixels differ (tolerance 0.200%)
            Worst: home.outlets_near_you (0.44%), home.body (0.26%)
            ssim 0.9950
RESULT: FAIL
```

Quiescence settled normally — a renamed outlet still draws two badges —
so the visual layer caught it, not quiescence, and it named the rail the
change is on.

**E did not reproduce, and the honest reason is that the platform has
already closed it.** `dashboard_late_images` serves the four outlet
pictures 1.5s, 3.5s, 5.5s and 7.5s apart — the exact shape of the defect
measured during STOP-2, where a quiet screen photographed 44% different
in 7 runs out of 8. The run **passed**: `waitForSettle` counts those
image requests as in flight and waited for all four, so the screen was
fully painted before the shutter.

Reproducing it on hardware now needs a screen that changes while no
ticker runs *and* no request is in flight, which is not something an API
fixture can arrange. So the rule was extracted into `SteadyCapture` and
proven directly, against a dictated sequence of pictures: a converging
screen is photographed, a screen alternating between two states returns
**null** rather than whichever frame it caught, a size change is a
disagreement rather than a comparison, and a change under an ignore
rectangle does not prevent agreement. Seven tests. The device result is
recorded as a negative finding rather than dressed up as a pass.

## Running it

```bash
./scripts/run_e2e.sh              # /home, /orders, /profile
./scripts/run_e2e.sh --negatives  # and the flows that must fail
```

Measured, end to end:

```
  PASS  home
  PASS  orders
  PASS  profile
  PASS  journey
  PASS  home_stalled (failed, as it must)
  PASS  home_changed (failed, as it must)

  device   RZ8T11QETWM
  RESULT: PASS (6 flows)
```

A negative flow that **passes** fails the suite. A suite that only ever
checks things pass cannot tell a working check from a check that no
longer runs.

| | |
|---|---|
| Required services | none. The fixture server binds `127.0.0.1` and every route is answered from a committed file |
| Environment variables | all optional: `MYTEST_APP_DIR`, `MYTEST_DEVICE`, `MYTEST_MOCK_PORT` (8080), `MYTEST_TARGET`, `MYTEST_FLAVOR`, `MYTEST_OUT_DIR` |
| Mock API | started by the runner, `--mock-api 8080`, mapped in with `adb reverse` |
| App | `flutter run -t lib/main_mytest.dart --flavor example`, started by the runner |
| Reports | `out/e2e/<flow>/result.json` and `report.html` |
| Exit code | non-zero if any layer fails |
| Cleanup | the runner stops `flutter run`, force-stops the app and closes the server in a `finally` |

What it still needs is **a device**. Nothing here runs on a hosted
runner without one.

## Tests

| | Before | After |
|---|---|---|
| `flutter_testsmith_protocol` | 96 | 96 |
| `flutter_testsmith_engine` | 583 | **658** |
| `flutter_testsmith_cli` | 82 | **88** |
| `flutter_testsmith` | 238 | 238 |
| `figma_client` | 37 | 37 |
| `ai_client` | 20 | 20 |
| `examples/ecommerce_app` | 84 | 84 |
| **Platform total** | **1,140** | **1,221** |

81 new, none removed. In the application's own repository, 1,155 → 1,173
(+18 scenario contract tests).

| Area | Where | Count |
|---|---|---|
| Quiescence | `quiescence_test.dart` | 68 (+11, all `count:`) |
| Animation inventory | `animation_inventory_test.dart` | 18 (unchanged) |
| API scenarios | `scenario_test.dart` 20, `mock_api_server_test.dart` 16, `mock_api_determinism_test.dart` 6, app-side `scenario_determinism_test.dart` 18 | 60 |
| API-in-flow (E2E) | `api_expectation_test.dart` 20, `expect_api_step_test.dart` 15 | 35 |
| Reporting | `e2e_summary_test.dart` | 14 |
| Visual regression | `visual_comparator_test.dart` 19, `visual_validator_test.dart` 19, `steady_capture_test.dart` 7, `baseline_provenance_test.dart` 4 | 49 |

## Limitations

- **A device is still required.** Nothing here runs on a hosted CI runner
  without one attached. The fixture server and every unit test do; the
  five flows do not.
- **The two badges tick below the fold.** They are created on every run
  now, which is what STOP-2 lacked, but the offer strip sits under the
  bottom navigation bar at this viewport, so only part of one badge's box
  is inside the photographed area. The exclusion is real — 3,658 pixels
  leave the comparison — but smaller than it would be on a taller screen.
- **Dates render in the device's local timezone.** The fixture pins UTC
  instants; the order card formats them as `dd MMM yyyy | hh:mm a` local.
  The baseline is therefore valid for a device set to IST and would need
  re-recording on one set to anything else. Not detected automatically.
- **`count:` is a fixture-only key.** Against live data the number is
  unknowable and the declaration should leave it out — at which point the
  STOP-2 hole reopens for that screen. The key makes determinism *pay*;
  it does not make live runs safer.
- **Screenshot instability is proven by unit test, not on hardware.** See
  E above. The device attempt is recorded as a negative result.
- **The quiet period still cannot apply while a permitted animation
  runs.** Unchanged from STOP-2. A `setState` loop elsewhere on `/home`
  would not be caught by the frame check; the two-photograph rule covers
  the visual consequence, nothing covers a structural one.
- **A screen can still be quiet and unfinished** in the tree sense. Also
  unchanged. The two-photograph rule makes the visual consequence go
  away; a UI tree captured in a quiet window is still a tree of a
  half-loaded screen.
- **`/rewards` has no deterministic scenario.** `tabs.yaml` still walks
  it and still validates without a baseline. It was out of scope.
- **The application's own test suite is not run by `run_e2e.sh`.** It is
  1,173 Flutter tests and belongs to that repository's CI, not to this
  runner.
