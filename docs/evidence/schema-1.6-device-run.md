# Run schema 1.6 on a device: monotonic request durations

Device runs made to check what schema 1.6 measures on real hardware: that
a request's `durationMs` comes from the application's monotonic clock,
starts before the connection is opened, and is recorded as such. Every
value below is extracted from the runs' own `result.json`, `report.html`,
stdout and exit-code files, which are kept locally under
`out/schema-1.6-device/` (ignored by git, not committed).

**No run here passed end to end.** Each exited 1. What they establish is
narrower, and listed at the end.

## Baseline and device

- Code: commit `a6ea44a` plus the uncommitted schema 1.6 working tree.
  `out/schema-1.6-device/working-tree.txt` holds `git status` and SHA-256
  digests of the diff and of each untracked file, taken before the runs.
- Baseline: a separate `git worktree` at `a6ea44a`, with one file added -
  `product_slow.json`, byte-identical to the tree's (same SHA-256).
- Device: **SM-M127G**, serial `RZ8T11QETWM`, the handset in
  [device-runs.md](device-runs.md). Recorded 2026-10-04.
- Scenario: `product_slow`, which serves `GET /products/123` after a
  configured **`delayMs: 2000`**, inside the example client's 5 s timeout.
  Every other route inherits `default`.

```bash
# runs 1 and 2, from examples/ecommerce_app in each tree
dart run ../../packages/flutter_testsmith_cli/bin/testsmith.dart run tests/product.yaml \
    --device RZ8T11QETWM --mock-api 8080 --fixture product_slow --out <evidence>/artifacts

# run 3, from the repository root
dart run packages/flutter_testsmith_cli/bin/testsmith.dart run \
    out/schema-1.6-device/flows/product_late_login_tap.yaml --app examples/ecommerce_app \
    --device RZ8T11QETWM --mock-api 8080 --fixture product_slow --out <evidence>/artifacts
```

## The runs

| Run | Code | Exit | Verdict | Login tap at | Requests captured | `durationClock` |
|---|---|---:|---|---:|---:|---|
| `run1-schema-1.6` | Schema 1.6 tree, committed flow `tests/product.yaml` | 1 | FAIL (schema 1.6) | +1275 ms | 0 | monotonic |
| `run2-baseline-a6ea44a` | Baseline `a6ea44a`, committed flow `tests/product.yaml` | 1 | FAIL (schema 1.5) | +1277 ms | 0 | absent |
| `run3-schema-1.6-late-tap` | Schema 1.6 tree, evidence flow `product_late_login_tap.yaml` | 1 | FAIL (schema 1.6) | +3604 ms | 3 | monotonic |

### Runs 1 and 2: the login tap that sent nothing

In both, `tap "login.submit"` completed, the application stayed on
`/login`, no request was captured and the mock API reported none. The
baseline fails identically on the same device, scenario and command, so
this is **not caused by schema 1.6**. With no request made, none of the
1.6 timing code ran.

What is known about the cause, and what is not:

- The application process logged no error. The 42 `E/flutter` lines in
  run 1's logcat all come from another application on the handset (pid
  23330), logged between 12:49 and 22:48; none fall in the run.
- The tap target is right when tapped later: `testsmith smoke` on the same
  handset and tree tapped `PhysicalPoint(360, 518)` - the point recorded
  on 2026-09 in device-runs.md - and captured `POST /auth/login 200` and
  `GET /home/summary 200`, exit 0.
- Both failing runs tapped about 1.28 s after the run began, after a first
  settle of about 1.27 s. The 2026-10-02 run of the same flow on this
  handset tapped at +2.961 s and logged in.
- `run` does not record where it tapped, so whether the early tap missed
  or arrived before the application accepted input is **not established**.
  It is recorded as an open, pre-existing issue.

### Run 3: the measurement

Run 3 used a copy of `tests/product.yaml` with one `screenshot` step and a
second `waitForSettle` before the login tap - a deviation, made only to
move the tap later; every other step is the same. The login went through.

`sessionId` `07536f11-b838-4ff9-8732-0c7d050cbe84`; `capture: active`, no
`reasons`, `orphanResponses: 0`, `durationClock: monotonic`.

| Request | Screen | Status | `durationMs` | `requestedAt` | `respondedAt` | stamps differ by |
|---|---|---:|---:|---|---|---:|
| POST http://127.0.0.1:8080/auth/login | /login | 200 | 824 | 2026-10-04T17:50:17.065137Z | 2026-10-04T17:50:17.282159Z | 217.022 ms |
| GET http://127.0.0.1:8080/home/summary | /home | 200 | 206 | 2026-10-04T17:50:17.581728Z | 2026-10-04T17:50:17.657204Z | 75.476 ms |
| GET http://127.0.0.1:8080/products/123 | /product/details | 200 | 2349 | 2026-10-04T17:50:19.130083Z | 2026-10-04T17:50:21.176276Z | 2046.193 ms |

The mock API's own log: `200 POST /auth/login`, `200 GET /home/summary`,
`200 GET /products/123 after 2000ms`.

- **At least the configured delay.** The server held its reply 2000 ms
  after receiving the request, so no correct measurement can be shorter;
  2349 ms is. The 349 ms beyond it is connection setup, request and
  response transfer, and the application reading the body - all inside the
  1.6 definition.
- **Not the wall-clock stamps.** Each `durationMs` differs from
  `respondedAt − requestedAt`: 2349 against 2046.193 ms. The request event
  is stamped at `close()`, after the connection exists; the duration
  starts before `openUrl`. The difference is largest for the first,
  cold connection (824 against 217.022 ms).
- **Labelled.** `report.html` heads both duration columns `Took
  (monotonic)` and states: "Durations: measured by the application on a
  monotonic clock, from before the connection was opened to the end of the
  response body or the error."

Run 3's FAIL is unrelated to network timing: five `figma-geometry` checks
on `/product/details` failed against the declared design (UI is FAIL
because the failing `validateScreen` step counts there too), and VISUAL is
SKIP because no baseline exists for the `product_slow` variant. Neither
the Figma nor the visual code is part of the 1.6 change; neither was
investigated here.

## What these runs establish

| | Established | Not established |
|---|---|---|
| Capability | The handset's SDK advertised `monotonicNetworkTiming` (smoke) and the record says `monotonic` (runs 1, 3) | - |
| Duration of a delayed request | 2349 ms for a 2000 ms server delay, on the monotonic clock | Behaviour under a device wall-clock change during a request (unit-tested only) |
| Connection setup included | Each duration exceeds its wall-stamp difference | A connection failure's duration on a device (unit-tested only) |
| Older SDK | The baseline wrote schema 1.5 with no `durationClock` | A 1.6 CLI against an older SDK (unit-tested only) |
| The committed flow | - | Why its login tap sends nothing on this handset today, at either commit |
| The application | - | Any passing verdict |
