# Run schema 1.5 on a device

One `testsmith run` on real hardware, made to check what the 1.5 network
record and step offsets look like when a real application produces them.
Every value below is quoted from that run's `result.json`, its
`report.html`, or its terminal output.

**This was not a passing run.** It exited 2 with an overall verdict of
ERROR, for a reason that has nothing to do with schema 1.5 (§1). What it
establishes is narrower: the run's capture, timing and report rendering on
a device. It says nothing new about whether the application is correct.

## The run

Device: **SM-M127G**, serial `RZ8T11QETWM` - the physical handset in
[device-runs.md](device-runs.md). Recorded 2026-10-02, against the working
tree that became the schema 1.5 commit (parent `8d4cd84`).

```bash
cd examples/ecommerce_app
dart run ../../packages/flutter_testsmith_cli/bin/testsmith.dart run tests/product.yaml \
    --device RZ8T11QETWM --mock-api 8080 --out <scratch>/device-run
```

`<scratch>` stands in for a local temporary directory, the only value in
this file that is not quoted exactly as the run printed it. `--out` was
pointed outside the repository deliberately: `examples/ecommerce_app/out`
is not ignored by git.

## 1. The verdict, and why it was ERROR

```
  UI       FAIL    Bad state: validation failed: 0 failed, 1 errored
  API      PASS
  FIGMA    ERROR   the Figma token env:FIGMA_TOKEN resolved to nothing. Set the FIGMA_TOKEN environment variable, or put it in a .env file that is not committed.
  VISUAL   PASS
  OVERALL  ERROR
```

Exit code **2**. `FIGMA_TOKEN` was not set on the host, so the screen's
declared design could not be loaded. Exit 2 is the documented contract for
a run that could not establish what it was asked to (E-04).

The **UI FAIL** above is not a UI defect, and it is not a schema 1.5
behaviour. `validateScreen` throws when its report contains an ERROR, and
the executor files that throw as a failed step, so the Figma ERROR is also
counted against the UI dimension - "0 failed, 1 errored". That is the code
at `8d4cd84`, unchanged by 1.5, and recorded here as a separate open issue.

## 2. Step offsets

`result.json` `startedAt`: `2026-10-02T16:05:19.039098Z`.

| `startedOffsetMs` | `durationMs` | Status | Step |
|---:|---:|---|---|
| 0 | 1 | ok | launch the app |
| 1 | 2960 | ok | wait for the screen to settle |
| 2961 | 628 | ok | tap "login.submit" |
| 3590 | 986 | ok | expect to be on "/home" |
| 4577 | 1338 | ok | wait for the screen to settle |
| 5915 | 179 | ok | tap "home.open_product" |
| 6095 | 104 | ok | expect to be on "/product/details" |
| 6199 | 1583 | ok | wait for the screen to settle |
| 7782 | 2975 | failed | validate the screen (automatic) |

Monotonic and contiguous: each step begins 0 or 1 ms after the previous
one ended, the difference being whole-millisecond truncation of two reads
of the same stopwatch.

## 3. Session

The terminal printed `› handshake complete for session
7b261101-1255-4d50-9b8f-61617cf4f533`, and `result.json` records
`"sessionId": "7b261101-1255-4d50-9b8f-61617cf4f533"`. The same id.

## 4. The network record

`"capture": "active"`, no `reasons`, `"orphanResponses": 0`, three
exchanges:

| `requestedAt` (device clock) | Request | `screenId` | Status | `durationMs` |
|---|---|---|---:|---:|
| 16:05:14.779703 | POST http://127.0.0.1:8080/auth/login | /login | 200 | 236 |
| 16:05:15.292724 | GET http://127.0.0.1:8080/home/summary | /home | 200 | 92 |
| 16:05:16.973857 | GET http://127.0.0.1:8080/products/123 | /product/details | 200 | 60 |

The mock API's own log agrees - three requests, each answered 200:

```
mock API served
  200  POST /auth/login
  200  GET /home/summary
  200  GET /products/123
```

**Attribution.** Only `/product/details` was validated, and its
`screens[].exchanges` holds one entry: `/products/123`, request id
`903479b6-ad56-4bcd-a08d-a4d2809e86b6`, the same id as its row above. The
`/login` and `/home` requests appear in `network.exchanges` and nowhere
else - before 1.5 they were in no part of the report at all. No request in
this run was unattributed.

`active` means capture was on and none of the losses the engine can detect
occurred. It is not a claim that the application made no other request: the
`scope` written into the record lists what the capture never sees.

## 5. The clock-skew defect, found by this run

The page this run wrote put steps and requests in one list, sorted by time.
Its timeline, as rendered by the code under test at the time:

```
16:05:14.779 api  POST http://127.0.0.1:8080/auth/login      2xx 236ms
16:05:15.292 api  GET http://127.0.0.1:8080/home/summary     2xx 92ms
16:05:16.973 api  GET http://127.0.0.1:8080/products/123     2xx 60ms
16:05:19.039 step launch the app                             ok  1ms
16:05:19.040 step wait for the screen to settle              ok  2960ms
16:05:22.000 step tap "login.submit"                         ok  628ms
...
```

Every request sorted before the run's first step, and the login request
**before the tap that sent it**. The two times come from two clocks: a
step's is `startedAt` plus its offset, on the host; a request's is the
application's own stamp, on the device.

What the run shows about those clocks, and how far it can be pushed:

- The tap began at host time `16:05:19.039098 + 2.961 s = 16:05:22.000098`.
- The login request it sent is stamped `16:05:14.779703` on the device.
- A request cannot precede its cause, so the host clock was ahead of the
  device clock by **at least 7.220 s**.

That is a lower bound, not a measurement of the offset, and it rests on one
inference: that this POST was sent by that tap. It is the only POST in the
flow, and the application opens on its sign-in screen. Nothing in a run
measures the offset itself.

**The correction.** The timeline is now two lanes, "Steps · host clock" and
"Requests · device clock", each in its own clock's order and never sorted
against the other. The page says the difference between the clocks was not
measured.

**Re-render verification.** This run's own `result.json`, rendered again by
the corrected `HtmlReporter` - no second device run, because the change is
in rendering alone:

```
host lane rows:   9
device lane rows: 3
request in host lane: false
step in device lane:  false
device order login<home<product: true
external resources: false
scripts: 1
```

## What this run did and did not establish

| | Established here | Not established here |
|---|---|---|
| Step offsets | Recorded, monotonic, contiguous | - |
| `sessionId` | Equals the handshake's | - |
| Capture state | `active` on a real build | `partial` and `unavailable`, which unit tests cover |
| Request attribution | Unvalidated screens reach the run-wide list | An unattributed request on a device |
| Outcomes | Three 200s | HTTP errors, failures, timeouts and unanswered requests on a device, which unit tests cover |
| Redaction in error text | - | Not exercised: nothing failed. Covered by a real-socket test, `http_overrides_capture_test.dart` |
| The application | - | Any verdict: the run ended ERROR on a missing Figma token |
