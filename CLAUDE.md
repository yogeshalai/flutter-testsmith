# CLAUDE.md

Durable context for Claude Code sessions in this repository. Read this
first; it is the index, not the content.

---

## What this is

**Flutter Testsmith** — an AI-native testing platform for Flutter,
developed as a Dart pub workspace. A conventional E2E tool validates
`user action -> expected result`. This one validates the whole chain:
API request, API response, app state, widget tree, UI field values,
Figma spec, screenshot, visual comparison, then AI *explanation*.

**Current focus: architectural consistency and compatibility with
Flutter projects this repository did not grow up with.** The product is
**one** package, `flutter_testsmith` (`packages/flutter_testsmith/`),
which holds the whole implementation as components
([ADR-0011](docs/adr/0011-single-published-package.md)). The five packages
it used to depend on have all moved inside it:

| Component | Status |
|---|---|
| SDK | `lib/flutter_testsmith.dart`, `lib/src/` (the app-side import) |
| Engine | migrated: `lib/src/engine/`, public `lib/engine.dart` |
| CLI | migrated: `lib/src/cli/`, executable `bin/testsmith.dart` (`dart run flutter_testsmith:testsmith`) |
| Figma | migrated: `lib/src/figma/`, public `lib/figma.dart` |
| AI | migrated: `lib/src/ai/`, public `lib/ai.dart` |
| Protocol | migrated: `lib/src/protocol/`, public `lib/protocol.dart`, also re-exported by the SDK |

It is not published yet: `publish_to: none` stays until the
release-readiness audit. Do not add further publishing, versioning or
changelog machinery unless asked.

The current state of the work lives in one file:
[docs/PROJECT_STATE.md](docs/PROJECT_STATE.md). It is the only document
expected to change every milestone. Everything else is either durable or
a point-in-time report.

---

## Canonical repository

**This repository — `github.com/yogeshalai/flutter-testsmith` — is the
only place Flutter Testsmith changes.** Every change, fix and release
happens here, and every pub.dev release is published from a clean
checkout of this repository's `main`.

- The earlier private development repository is frozen. Make no
  commits there and port nothing back to it. Its history is not public
  and is not a source for changes.
- The one published package is `flutter_testsmith`. Its `repository:`
  field points at its folder here; pub.dev checks that the published
  `pubspec.yaml` exists at that path, so the folder is not moved without
  updating the pubspec.
- Commits are made as `yogeshalai <yogeshalai17@gmail.com>`, set in this
  repository's local git config.
- `flutter_testsmith` declares `publish_to: none`. That is the rail against
  an accidental `dart pub publish`. The ADR-0011 migration is complete;
  the rail comes off only at the release-readiness audit, and
  `dart run scripts/check_dependencies.dart --release` fails until it
  does (that `publish_to` line is the only item it still reports).

---

## The governing principle

**The deterministic engine decides. AI explains, suggests, and
prioritises.**

Two consequences, both enforced in code rather than by convention:

1. A pass/fail verdict never carries a confidence score.
2. AI never mutates a user-authored file.

Reasoning: [ARCHITECTURE §2](docs/ARCHITECTURE.md).

---

## Invariants — do not reverse these

Each is enforced by a named test or script. If you are about to change
behaviour one of these describes, read the reasoning first and say out
loud that you are changing it.

| Invariant | Enforced by | Reasoning |
|---|---|---|
| The app under test must not link the testing brain: nothing reachable from `lib/flutter_testsmith.dart` imports engine, CLI, Figma or AI code (rule A). Its package-level form, "`flutter_testsmith` never depends on `flutter_testsmith_engine`", retired with that package (ADR-0011) | `scripts/check_dependencies.dart` (CI step 1), rules in `scripts/import_graph.dart`, tests in `test/import_graph_test.dart` | ARCHITECTURE §6, ADR-0011 |
| Protocol, engine, CLI, Figma and AI code never reaches Flutter: no `package:flutter`, `dart:ui`, Flutter-dependent package or SDK file in its import closure (rule B). Its package-level form retired with the packages; the engine source scan still runs over `lib/src/engine` | same script | ARCHITECTURE §6, ADR-0003, ADR-0011 |
| `flutter_testsmith` never path- or git-depends back into this repository (until ADR-0011 the protocol package was held to this too) | same script | docs/E-01 |
| The published package depends only on pub.dev and the Flutter SDK (rule C). A workspace-member dependency is *pending* during the migration; `--release` fails on anything pending | same script, `--release` | ADR-0011 |
| No AI output can reach a pass/fail verdict | `flutter_testsmith/test/engine/ai_boundaries_test.dart` | ADR-0009 |
| An unrecognised AI claim level parses to `hypothesis`, the weakest | `ai_boundaries_test.dart` | ADR-0009 |
| A model outage is *unavailable*, never a test failure | `ai_boundaries_test.dart` | ADR-0009 |
| No request or response body is ever sent to a model | `ai_boundaries_test.dart` | ADR-0009 |
| Generated flows are stamped `status: proposed` by the generator — not by the model — and refuse to run | `generated_scenario_validity_test.dart`, `test_generator_test.dart` | IMPLEMENTATION_PLAN Phase 11 |
| Visual baselines are never re-recorded automatically | `flutter_testsmith/test/engine/visual_validator_test.dart` | ADR-0008 |
| The SDK cannot arm in release without an explicit opt-in; three independent layers | `flutter_testsmith/test/sdk/gating_test.dart` | ARCHITECTURE §9.2 |
| Redaction happens at capture, in-process, allow-by-exception | `redaction_test.dart`, `secret_leakage_test.dart` | ARCHITECTURE §13 |
| Secrets are referenced by variable *name*; a literal key in `ai.yaml` is a parse error | `secret_ref_test.dart`, `secrets_neutrality_test.dart` | ADR-0009 |
| `skip` is not `pass` — a check that cannot honestly be made says so | validator tests throughout | docs/E-06 |
| ENVIRONMENT is not FAIL — an unevaluable run exits 2 | `preflight_runner_test.dart`, `suite_command_exit_codes_test.dart` | docs/E-04 |
| Impact analysis excludes a flow only on positive evidence that every changed file is unrelated to it | `impact_stress_test.dart`, `evidence/impact_matrix.md` | README, "Which tests a change makes worth running" |
| The platform never guesses between candidates: not devices, not duplicate test ids, not two configs for one screen | `duplicate_screen_config_test.dart`, `device_selection` tests | doc comment in `project_config.dart` |

---

## Host-environment rules

These came out of making the tool work against applications outside this
repository. Each replaced several commands that answered the same
question differently. **One rule, one file, every command** — a second
answer to any of these is a defect, not a convenience.

| Question | The one rule | Owner |
|---|---|---|
| Where is the application? | `--app` if given (it need only exist); otherwise the nearest ancestor holding `pubspec.yaml`. Never a fallback to a directory nobody named. | `flutter_testsmith/lib/src/cli/project_root.dart` |
| Where does `app: path:` in a suite or auth file point? | Relative to the *declaring file*; an absolute path is taken as written. | `project_root.dart` |
| Where does `--out` write? | A relative path resolves against the **resolved application root**; an absolute one is the directory named. | `flutter_testsmith/lib/src/cli/output_path.dart` |
| Which `adb`? | `MYTEST_ADB` > `ANDROID_HOME` > `ANDROID_SDK_ROOT` > `PATH`, reporting which source was used and which were set but held nothing. | `flutter_testsmith/lib/src/engine/device/adb_location.dart` |
| Which `flutter`? | **PATH only**, resolved to one absolute executable with provenance. On Windows only runnable wrappers count (`.bat`, `.cmd`, `.exe`), never the extensionless script. | `flutter_testsmith/lib/src/engine/environment/flutter_location.dart` |
| Where do credentials come from? | The process environment first, then the first `.env` found beside the application, then beside the caller. The real environment always wins, so CI is never overridden by a developer's file. | `dotenv.dart`, `secrets/env_secret_resolver.dart` |
| Which Android package does a run drive? | A flow declares `appId:`. `inspect` and `smoke`, which have no flow, require `--app-id` and verify it against the device. | `dsl/test_flow.dart`, `device_selection.dart` |
| A missing external tool | Reported as something to install, with an exit code — never an unhandled `ProcessException`, which exited 255 and leaked absolute paths into piped output. | commit 04d3696 |

**Deliberately not supported.** Do not add these without asking:

- `FLUTTER_ROOT`, `.fvmrc`, `.fvm/flutter_sdk`, or any other Flutter
  override. PATH is the documented contract — E-04 states the failure as
  "`flutter` is not on PATH" and the remedies say to add it there. A test
  asserts that setting `FLUTTER_ROOT` or `MYTEST_FLUTTER` changes
  nothing: `flutter_discovery_test.dart`.
- Dart SDK discovery separate from Flutter's. See
  [docs/PROJECT_STATE.md](docs/PROJECT_STATE.md) for why it was deferred.

---

## Verifying a change

CI ([.github/workflows/test.yml](.github/workflows/test.yml)) is the
authoritative sequence. Locally, in this order:

```bash
dart pub get                                # one resolve, whole workspace
dart run scripts/check_dependencies.dart    # the layering rules, first
dart analyze --fatal-infos

cd packages/flutter_testsmith          && dart test test/protocol
cd packages/flutter_testsmith          && dart test test/engine
cd packages/flutter_testsmith          && dart test test/cli
cd packages/flutter_testsmith          && dart test test/figma
cd packages/flutter_testsmith          && dart test test/ai
cd packages/flutter_testsmith          && flutter test test/sdk
cd examples/ecommerce_app              && flutter test
```

The dependency check runs first on purpose: a violation makes every later
result less meaningful.

**Device-dependent work cannot be verified by the suites above.**
`./scripts/run_e2e.sh` (and `--negatives`) needs an attached Android
device. A claim about device behaviour needs a device run, and the
measurement belongs in `docs/evidence/`.

The root `test/` directory (`packaging_test.dart`,
`external_consumer_test.dart`, `local_registry_test.dart`) runs as its
own CI step, `dart test test/` from the repository root. It needs no
device, but `flutter` on PATH and pub.dev. It was added to CI
after passing locally on Windows (about 30s); its first Linux run is
whatever CI reports next. Locally:

```bash
dart test test/                             # from the repository root
```

---

## Before changing architecture

1. Read [docs/PROJECT_STATE.md](docs/PROJECT_STATE.md) — what is built,
   what is open, and which documents are point-in-time.
2. Read the doc comment on the file you are about to change. This
   codebase puts the *why*, and the measurement that produced it, in the
   source. `project_root.dart`, `output_path.dart`, `adb_location.dart`,
   `flutter_location.dart` and `project_config.dart` each open with the
   defect that justified them.
3. Read `git log -1 --format=%B <commit>` for the relevant change. Recent
   commit messages carry the reasoning, the measurement, and what was
   deliberately left alone.
4. Check [docs/adr/](docs/adr/) for a decision that already covers it.
   **ADRs are immutable once accepted** — a reversal is a *new* ADR that
   supersedes the old one, and the original stays.

---

## Conventions

| Concern | Rule |
|---|---|
| Line endings | LF, enforced by `.gitattributes`. Windows host: count bytes and trust `git diff --check`; `awk` and `grep` mis-measure CR here. |
| Public surface | At most one barrel per component; `src/` is private. In `flutter_testsmith` that is `lib/flutter_testsmith.dart` (the SDK), `lib/engine.dart`, `lib/figma.dart`, `lib/ai.dart` and `lib/protocol.dart`; the CLI has no public library, only the `testsmith` executable (ADR-0011). A still-separate package has one barrel |
| Semantic test IDs | Dotted lowercase: `product.add_to_cart` |
| Wire namespace | `ext.mytest.*` — **frozen deliberately**. Renaming a protocol is a protocol change (434a57f). |
| Operator variables | `MYTEST_*` — also frozen; it is the operator's contract with their own shell and CI |
| CLI layering | The CLI does argument parsing and output formatting only. A command file that grows logic pushes it down into the engine. |
| Evidence | A claim about device behaviour cites a run under `docs/evidence/`, generated by the run that produced it |

---

## Vocabulary

Source comments and tests reference milestone identifiers. Decoder:

| Prefix | Meaning | Defined in |
|---|---|---|
| `Phase 1`–`Phase 12` | The original build-out | `docs/IMPLEMENTATION_PLAN.md`, `docs/PHASE_12_ACCEPTANCE.md` |
| `STOP-1`–`STOP-3` | Determinism milestones | `docs/STOP_*.md` |
| `E-01`–`E-06` | Compatibility **milestones**, one document each | `docs/E-0*.md` |
| `E-01`–`E-10` | Compatibility **findings** — a *different* numbering that collides with the above. Finding E-05 is a go_router object-hash route name; milestone E-05 is authentication setup. Check which is meant. | `docs/EXTERNAL_APP_VALIDATION.md` |
| `L1`–`L12` | Phase 12 limitations — **some are now superseded** | `docs/PHASE_12_ACCEPTANCE.md`; current status in `docs/PROJECT_STATE.md` |
| `R1`–`R7` | Risk register | `docs/TECHNICAL_RISKS.md` |
| `S1`–`S10`, `D-12` | Consolidation steps; these appear in code comments only | `docs/PROJECT_STATE.md` |
| `N-01` | The Flutter Testsmith rename | commit 434a57f |
