# Repository Structure

**Date:** 2026-09-10, kept current.

This describes the layout. The *(Phase N)* markers below record which phase
created a directory - the repository never carries empty placeholder folders,
so a marked directory exists once that phase has landed, and all of them now
do.

For the layout of an **application under test**, which is a different
question, see "An application under test" at the end.

---

## Top level

```
flutter_testsmith/
├── pubspec.yaml                 # Dart pub workspace root
├── analysis_options.yaml        # strict lints, inherited by all packages
├── .gitignore
├── README.md
├── packages/
├── integrations/                # (Phase 5+)
├── examples/
├── docs/
└── scripts/
```

The workspace root `pubspec.yaml` declares members and resolves one shared
`.dart_tool/package_config.json`. A single `dart pub get` at the root is
sufficient for every package.

---

## packages/

### `packages/flutter_testsmith_protocol/` - the contract

Pure Dart. **Zero dependencies** other than `meta`. This constraint is
deliberate: the package is linked into production applications through
`flutter_testsmith`, so anything it depends on becomes a dependency of every app under
test.

```
flutter_testsmith_protocol/
├── lib/
│   ├── flutter_testsmith_protocol.dart        # barrel; the entire public surface
│   └── src/
│       ├── envelope.dart         # TestEvent, AppContext, EventType
│       ├── payloads/             # one file per sealed payload subtype
│       ├── handshake.dart        # HandshakeRequest/Response, version rules
│       ├── version.dart          # protocolVersion constant + compatibility
│       └── json.dart             # shared codec helpers
└── test/
    ├── fixtures/                 # canonical JSON, asserted by BOTH sides
    └── *_test.dart
```

`test/fixtures/` is load-bearing rather than incidental: the same files are
asserted by `flutter_testsmith` and `flutter_testsmith_engine` tests, so a change that breaks one
side fails the other's suite. This is the primary defence against protocol
drift.

### `packages/flutter_testsmith/` - in-app instrumentation

A Flutter package, added to the application under test.

```
flutter_testsmith/
├── lib/
│   ├── flutter_testsmith.dart             # barrel: TestSdk, TestSdkConfig, TestKey, TestId
│   └── src/
│       ├── config.dart           # TestSdkConfig, RedactionPolicy
│       ├── gating.dart           # the three production-safety layers
│       ├── channel/              # SdkChannel interface + VmServiceChannel
│       ├── buffer/               # bounded ring buffer
│       ├── navigation/           # TestNavigatorObserver, router adapters
│       ├── identity/             # TestKey, TestId, ID resolution
│       ├── inspection/           # (Phase 2) hybrid element+semantics walk
│       └── capture/              # (Phase 3) CaptureAdapter implementations
└── test/
```

### `packages/flutter_testsmith/lib/src/engine/` - the brain

Until ADR-0011 step 2 this was its own package, `flutter_testsmith_engine`.
It is now a component of `flutter_testsmith`, with its tests in
`packages/flutter_testsmith/test/engine/`. Its code is pure Dart and
**never imports Flutter** (rule B in `scripts/check_dependencies.dart`) -
this is what keeps the CLI compilable to a native binary and validation
logic unit-testable in milliseconds.

```
flutter_testsmith/
├── lib/
│   ├── engine.dart               # the engine's barrel
│   └── src/engine/
│       ├── transport/            # SdkTransport, VmServiceTransport, flutter run driver
│       ├── device/               # DeviceController, AdbDeviceController, coordinates
│       ├── session/              # SessionManager, ScreenSession, correlation, settle
│       ├── inspection/           # (Phase 2) UI tree model, element lookup
│       ├── validation/           # (Phase 4) validators, transformations, rules
│       ├── dsl/                  # (Phase 4) YAML parsing, sealed Step, executor
│       ├── reporting/            # (Phase 4) result.json, HTML renderer
│       └── config/               # project config loading
└── test/
```

`src/` subdirectories are the module boundaries the specification asks for.
They are directories rather than separate packages (ADR-0003); the barrel
keeps their public surface explicit, so any of them can later be extracted
into a real package without changing a single import site.

### `packages/flutter_testsmith_cli/` - the `testsmith` binary

```
flutter_testsmith_cli/
├── bin/testsmith.dart
├── lib/src/commands/             # one file per command
└── test/
```

The CLI holds **argument parsing and output formatting only**. All behaviour
lives in `flutter_testsmith_engine`, so every capability is testable without a process
boundary. A command file that grows logic is a smell to be pushed down.

---

## integrations/ *(Phase 5+)*

```
integrations/
├── flutter_testsmith_figma/   # REST client, normalised FigmaScreenSpec, response cache
└── ai_client/                 # Claude client, prompt templates, strict output contracts
```

Separate from `packages/` because both are **optional** and both talk to
external paid services. Keeping them out of the core dependency graph means
the platform builds, tests and runs with neither configured.

---

## examples/

```
examples/
└── ecommerce_app/
    ├── lib/          # Login, Home, ProductList, ProductDetails, Cart, Checkout
    ├── mock_api/     # (Phase 3) fixture-driven mock server
    ├── figma/        # (Phase 5) normalised design specs
    ├── mappings/     # (Phase 4) per-screen mappings.yaml
    └── tests/        # (Phase 4) product.yaml and friends
```

Phase 1 ships a minimal two-screen version of this app - enough to exercise
navigation events and nothing more. It grows into the full six-screen
application in Phase 4, the first phase that can actually validate it.

---

## docs/

```
docs/
├── ARCHITECTURE.md
├── IMPLEMENTATION_PLAN.md
├── TECHNICAL_RISKS.md
├── REPOSITORY_STRUCTURE.md
└── adr/
    └── NNNN-short-title.md
```

ADRs are immutable once accepted. A reversed decision gets a **new** ADR that
supersedes the old one; the original stays, so the reasoning behind a past
choice remains readable.

---

## scripts/

```
scripts/
├── check_dependencies.dart    # asserts the acyclic dependency rules
├── package_boundaries.dart    # public-surface checks
├── local_registry.dart        # a local package repository, for E-01
├── serve_local_registry.dart  # serves it over HTTP
└── run_e2e.sh                 # the deterministic suite; needs a device
```

`check_dependencies.dart` mechanically enforces the two invariants that
matter: `flutter_testsmith` must not depend on `flutter_testsmith_engine`, and `flutter_testsmith_engine` must
not depend on Flutter. Architectural rules that are only written down erode;
these two are worth a CI check.

---

## Conventions

| Concern | Rule |
|---|---|
| Package names | `snake_case`. The in-app SDK takes the bare product name, `flutter_testsmith`, because it is the only package a consumer ever names; the rest take it as a prefix (`flutter_testsmith_protocol`, `_engine`, `_cli`). The workspace root cannot share a name with a member, so it is `flutter_testsmith_workspace`. `ai_client` keeps its own name - it describes what it talks to, not who ships it. The Figma integration was `figma_client` on the same principle until pub.dev release preparation found that name owned by an unrelated package; it is now `flutter_testsmith_figma`. Older milestone reports and evidence keep the old name as written at the time. |
| Public surface | Exactly one barrel file per package; `src/` is private |
| Semantic test IDs | Dotted lowercase: `product.add_to_cart` |
| VM Service RPCs | Namespaced `ext.mytest.<method>` |
| Event type names | `SCREAMING_SNAKE_CASE` on the wire, `PascalCase` in Dart |
| Tests | Mirror `lib/src/` path under `test/`, suffixed `_test.dart` |
| Versioning | Protocol and `result.json` schema are versioned independently |
| Line endings | LF, enforced by `.gitattributes` (Windows host, mixed tooling) |

---

## An application under test

Not part of this repository, except that `examples/ecommerce_app` is one.
The application root is what `--app` names, or the nearest ancestor holding
a `pubspec.yaml` (ARCHITECTURE section 17.1), and every relative `--out`
resolves against it.

```
<app>/
├── pubspec.yaml          # the marker that makes this an application root
├── tests/                # flow YAML; tests/proposed/ holds generated ones
├── mappings/             # one mappings.yaml per screen
├── figma/                # normalised design specs; .cache/ is gitignored
├── auth/                 # auth setup files, credentials by env: name
├── device_profiles/      # named devices a suite can require
├── visual_baselines/     # committed and reviewed like any other file
└── mock_api/scenarios/   # fixture deltas against default.json
```

One file per screen in `mappings/` and `figma/`: two files naming one screen
are refused rather than resolved by directory order.

**Unresolved.** Doc comments in `project_root.dart` describe a `mytest/`
tree, and commit `434a57f` records `mytest/{tests,suites,auth}/` as a
convention deliberately preserved for applications already organised that
way. Whether that is a second supported layout or a stale reference has not
been decided - see PROJECT_STATE.md section 5.
