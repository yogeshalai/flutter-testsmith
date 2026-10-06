# Project state

**As of:** 2026-09-20, commit `6749e7f`, branch `deterministic-e2e`.

The one document expected to change every milestone. Everything else in
`docs/` is either durable (ARCHITECTURE, ADRs, REPOSITORY_STRUCTURE) or a
point-in-time report that is never edited after the fact (the Phase,
STOP and E milestone documents).

There is no issue tracker and no git remote. This file is the roadmap.

---

## 1. Which document is authoritative

| Document | Kind | Read it for |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | durable | Boundaries, protocol, transport, SDK, engine, host environment |
| [adr/](adr/) | durable, immutable | Why a decision was made, and what was rejected |
| [REPOSITORY_STRUCTURE.md](REPOSITORY_STRUCTURE.md) | durable | Layout and naming conventions |
| [TECHNICAL_RISKS.md](TECHNICAL_RISKS.md) | durable | Risk register R1–R7, with what was measured |
| [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) | **point-in-time** | Phases 1–11 as planned. Stops at 11; it is not a roadmap for current work. |
| [PHASE_12_ACCEPTANCE.md](PHASE_12_ACCEPTANCE.md) | **point-in-time** | Capability-by-capability verdicts as of Phase 12. Several limitations are now superseded — see §4. |
| [../PHASE_12_HARDENING.md](../PHASE_12_HARDENING.md) | **point-in-time** | The hardening plan and what it found |
| `STOP_1..3_*.md` | **point-in-time** | Determinism milestones, each with its own limitations section |
| `E-0*.md` | **point-in-time** | External-application compatibility milestones |
| [EXTERNAL_APP_VALIDATION.md](EXTERNAL_APP_VALIDATION.md) | **point-in-time** | What broke when the platform met an application it did not grow up with |
| [evidence/](evidence/) | generated | Device measurements and defect matrices, produced by the runs they describe |
| **This file** | living | What is built, what is open, what is next |

A point-in-time report is not wrong when it disagrees with the code — it
is *old*. The implementation and its tests are more authoritative than
any document here.

**One exception to "never edited":** on 2026-10-05, in preparation for
public release, every document was anonymised. The external application
these reports measured is called **ExternalApp**; its repository
location, backend host, Figma file key, file name and version are
`<redacted>`; its application ids, flavor, environment and suite names,
API routes and the account persona were replaced with `com.example.*`,
`example`, `test` and similar synthetic values; and Figma node ids were
renumbered (`909:1` is the Login frame) to match the anonymised fixtures.
No measurement, verdict or conclusion was changed. The originals remain
in git history before that date.

---

## 2. What is built

Eleven CLI commands: `auth`, `doctor`, `devices`, `figma`, `generate`,
`impact`, `inspect`, `preflight`, `run`, `smoke`, `suite`.

One package plus the example application, both workspace members:
`flutter_testsmith`, which since ADR-0011 holds the whole implementation
(the SDK; the protocol at `lib/src/protocol/`; the engine at
`lib/src/engine/`; the CLI at `lib/src/cli/` with `bin/testsmith.dart`;
Figma at `lib/src/figma/`; AI at `lib/src/ai/`), and
`examples/ecommerce_app`.

The Figma integration was named `figma_client` until pub.dev release
preparation found that name owned by an unrelated package. Milestone
reports and evidence written before the rename keep the old name.

The Figma fixtures in `flutter_testsmith/test/figma/fixtures/`
and the device captures in `flutter_testsmith/test/engine/fixtures/external/`
keep the geometry, typography, colour and structure of what was captured,
along with Figma's auto-generated layer names and generic UI copy. Every
client-identifying name or string, and every node id, component key,
image ref and piece of file metadata, is synthetic.

Capability coverage is recorded, with named evidence for every row, in
[PHASE_12_ACCEPTANCE.md](PHASE_12_ACCEPTANCE.md); the milestones after it
are E-01 through E-06 and the consolidation work in §3. 175 test files
across eight suites. Commit `64dbbac` recorded 2,753 passing tests; that
number has not been re-measured since.

---

## 3. The consolidation programme (current focus)

Making the package architecturally consistent and usable against Flutter
projects that were not built alongside it. Every item below is committed
on `deterministic-e2e` and **not pushed** — there is no remote.

The `S` and `D` identifiers appear in source comments and test names.
They were never commit-message titles, so this table is the only mapping
from an identifier to the change that introduced it.

| ID | Commit | What it established |
|---|---|---|
| S2–S7 | `7e17cbf` | One project-root rule; impact paths and the index sharing a repo-root base; `--app-id` required and device-verified; a device probe that distinguishes "no" from "could not ask"; one adb discovery policy |
| N-01 | `434a57f` | The Flutter Testsmith identity. The SDK takes the bare name; the rest take it as a prefix. `ext.mytest.*`, `MYTEST_*`, `mytest/{tests,suites,auth}/` and `lib/main_mytest.dart` were **deliberately left alone** — renaming a protocol, an operator contract or an on-disk layout is a behaviour change wearing a naming change's clothes. |
| S8 | `36e770f` | One base for every `--out`: the resolved application root |
| S9-A | `f5353ce` | One resolved `flutter` executable, with provenance. PATH remains the only source. |
| S10-A | `bfc9457` | Flutter discovery made cwd-stable — a relative PATH entry was silently running a different SDK |
| — | `64dbbac` | Figma credential parity: `figma pull` now resolves through the same `.env` mechanism as the other four commands |
| — | `04d3696` | A missing `git` or `adb` is reported, not an exit-255 stack trace that leaked absolute paths |
| — | `d16b07e` | Figma output and cache boundary: the cache is pinned to `<app>/figma/.cache`, and a non-canonical `--out` warns |
| — | `6749e7f` | Two config files for one screen are refused instead of silently last-winning on `Directory.listSync()` order |

The rules these produced are summarised in
[../CLAUDE.md](../CLAUDE.md#host-environment-rules) and described in
[ARCHITECTURE §17](ARCHITECTURE.md).

### Deliberately deferred

Researched and **not** built. Read this before proposing them again:

- **FVM and `FLUTTER_ROOT` as Flutter SDK sources.** PATH is the
  contract E-04 documents and CI depends on. Widening it is a policy
  change, not a bug fix, and `flutter_discovery_test.dart` asserts the
  current narrowness so that widening it fails a test on purpose.
- **Separate Dart SDK discovery (the "S9-B" shape).** Not built.

From the run-report milestone (run schema 1.5, the network record).
Each is a separate decision rather than an omission:

- **Report history and retention** (`runs/<run-id>/`, a `latest`
  pointer). `--out` is currently overwritten by each run, as it always has
  been. A history changes the `--out` contract for `run` and for every
  per-test directory `suite.json` references, and a retention policy that
  prunes deletes files - both are the user's call. A run id belongs with
  it; `sessionId` already identifies the application session.
- **JUnit XML.** Fits `suite run` rather than `run`, and is an output
  format, not a reporting fact.
- **Tool, Flutter and Dart versions in `result.json`.** `doctor` reads
  them; recording them per run means running `flutter --version` in every
  run.
- **Error-text redaction beyond the request's own URL.** A client
  exception is redacted where it quotes the URL exactly as `Uri` prints it,
  which is how `dart:io` `HttpException` does. Other formats are not
  recognised.

---

## 4. Phase 12 limitations: current status

[PHASE_12_ACCEPTANCE.md](PHASE_12_ACCEPTANCE.md) lists L1–L12 and is not
edited after the fact. Status now:

| | Limitation | Status |
|---|---|---|
| L1 | `flutter_test` cannot drive a real socket | Open, by nature. Evidence is split across three places instead. |
| L2 | Test selection does not follow navigation | Open |
| L3 | A credential in a URL is not redacted | **Closed.** `RedactionPolicy.redactUrl` masks a sensitive query parameter at capture, by the same `isSensitive` rule as a header — the name survives, the value does not, and `?page=2` is untouched. The test that asserted the leak now asserts the redaction. |
| L4 | Visual baselines are per device resolution | Open |
| L5 | Ignore regions belong to a capture path, not a screen | Open |
| L6 | No scroll step | Open. The platform refuses an off-screen tap clearly rather than tapping nothing. |
| L7 | One text anchor per screen | Open |
| L8 | Platform views are invisible to the surface capture | Open |
| L9 | One API response per screen | Open |
| L10 | The Checkout Figma spec is hand-authored | Open; stated in the file itself |
| L11 | Android only | Open. Nothing is Android-specific except `AdbDeviceController`, but that remains an assertion rather than a measurement. |
| L12 | **Single flow per invocation, no suite runner** | **Superseded** by E-03: `testsmith suite run`, device profiles and baseline selection exist |

The same report's "Is it production-ready?" section names three blockers.
The first ("no suite runner") is superseded as above. The second
(single-device visual regression) and third (one application tested) both
still stand, though E-01 through E-06 and the consolidation work in §3
were the response to the third.

---

## 5. Open questions

Recorded because they are genuinely unresolved, not because a decision is
pending. Do not resolve one silently.

- **Two on-disk layouts for a project's test assets.** The example
  application and `project_indexer.dart` use
  `<app>/{mappings,tests,figma,auth,device_profiles,visual_baselines,mock_api}`.
  The doc comments in `project_root.dart` describe a `mytest/` tree, and
  commit `434a57f` records `mytest/{tests,suites,auth}/` as a convention
  deliberately preserved for applications already organised that way.
  Whether these are two supported layouts, or one stale reference, has
  not been decided.
- **Whether the `S`/`D` identifiers should survive in source comments.**
  They are useful only with §3 in hand.
- **The `E-NN` prefix means two different things.** `docs/E-01..E-06` are
  milestone documents; `E-01..E-10` in
  [EXTERNAL_APP_VALIDATION.md](EXTERNAL_APP_VALIDATION.md) are findings,
  numbered independently. Only E-01 means the same thing in both. Neither
  scheme has been renamed, so a reference has to be read in context.

---

## 6. Not in scope now

- **Publishing to pub.dev** is decided, not performed. The product is
  released as **one** package, `flutter_testsmith`. The five packages it
  used to depend on moved inside it as components
  ([ADR-0011](adr/0011-single-published-package.md)), because pub.dev
  refuses a published package whose dependencies it cannot serve.
  Migration complete. Engine: migrated (step 2). CLI: migrated (step 3).
  Figma: migrated (step 4). AI: migrated (step 5). Protocol: migrated
  (step 6). `flutter_testsmith` still declares `publish_to: none` until
  the release-readiness audit. `scripts/check_dependencies.dart` already
  enforces the import-graph form of the layering rules (A, B), and lists
  what still stands between the tree and a publishable package (C,
  pending). `--release` fails on anything pending. Releases are published
  from this repository only (CLAUDE.md, "Canonical repository").
- iOS. Impossible on the Windows development host (ARCHITECTURE §3), and
  the interfaces exist so it stays implementation rather than redesign.
- Cloud backend, dashboard, account system, history server
  (ARCHITECTURE §15).
- Exploratory navigation, where a model drives the app looking for
  trouble (IMPLEMENTATION_PLAN Phase 11, "Not built").
