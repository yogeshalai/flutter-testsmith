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
├── analysis_options.yaml        # includes flutter_testsmith's strict lints
├── .gitignore
├── README.md
├── packages/
├── examples/
├── docs/
└── scripts/
```

The workspace root `pubspec.yaml` declares members and resolves one shared
`.dart_tool/package_config.json`. A single `dart pub get` at the root is
sufficient for every package.

---

## packages/

### `packages/flutter_testsmith/lib/src/protocol/` - the contract

Until ADR-0011 step 6 this was its own package, `flutter_testsmith_protocol`.
It is now a component of `flutter_testsmith`, imported as
`package:flutter_testsmith/protocol.dart` and re-exported by the SDK, with
its tests in `packages/flutter_testsmith/test/protocol/`.

Pure Dart. Its code reaches **nothing** but `meta` and `dart:convert`:
rule B in `scripts/check_dependencies.dart` holds it to no Flutter, and
`test/packaging_test.dart` holds it to no other component. This constraint is deliberate: the protocol is linked
into production applications through the SDK, so anything it reaches
becomes part of every app under test.

```
flutter_testsmith/
├── lib/
│   ├── protocol.dart             # the protocol's barrel; its entire public surface
│   └── src/protocol/
│       ├── envelope.dart         # TestEvent, AppContext, EventType
│       ├── payloads/             # one file per sealed payload subtype
│       ├── handshake.dart        # HandshakeRequest/Response, version rules
│       ├── version.dart          # protocolVersion constant + compatibility
│       └── json.dart             # shared codec helpers
└── test/protocol/
    ├── fixtures/                 # canonical JSON, asserted by BOTH sides
    └── *_test.dart
```

`test/protocol/fixtures/` is load-bearing rather than incidental: the same files are
asserted by the SDK's and the engine's tests, so a change that breaks one
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

### `packages/flutter_testsmith/lib/src/cli/` - the `testsmith` binary

Until ADR-0011 step 3 this was its own package, `flutter_testsmith_cli`. It is
now a component of `flutter_testsmith`, run as `dart run
flutter_testsmith:testsmith`, with its tests in
`packages/flutter_testsmith/test/cli/`. It has no public library.

```
flutter_testsmith/
├── bin/testsmith.dart
├── lib/src/cli/commands/         # one file per command
└── test/cli/
```

The CLI holds **argument parsing and output formatting only**. All behaviour
lives in the engine (`lib/src/engine/`), so every capability is testable without a process
boundary. A command file that grows logic is a smell to be pushed down.

---

## The integrations: Figma and AI *(Phase 5+)*

Until ADR-0011 they were separate packages under `integrations/`:
`flutter_testsmith_figma` and `ai_client`. Both are now components of
`flutter_testsmith`, and `integrations/` no longer exists:

```
flutter_testsmith/
├── lib/figma.dart, lib/src/figma/   # REST client, normalised FigmaScreenSpec, response cache
├── lib/ai.dart,    lib/src/ai/      # provider-agnostic chat client, configuration
└── test/figma/, test/ai/
```

Both remain **optional at run time**: both talk to external paid services,
and the platform builds, tests and runs with neither configured. A
capability with no credential reports as unavailable rather than failing.

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
matter, over the import graph of the one package (ADR-0011): nothing
reachable from `lib/flutter_testsmith.dart` is engine, CLI, Figma or AI
code, and the protocol, engine, CLI, Figma and AI code never reaches
Flutter. (Before ADR-0011 they were stated as package dependencies:
`flutter_testsmith` must not depend on `flutter_testsmith_engine`, and the
engine must not depend on Flutter.) Architectural rules that are only written down erode;
these two are worth a CI check.

---

## Conventions

| Concern | Rule |
|---|---|
| Package names | `snake_case`. The one published package takes the bare product name, `flutter_testsmith`. Before ADR-0011 the components were packages named with that prefix (`flutter_testsmith_protocol`, `_engine`, `_cli`, `_figma`) plus `ai_client`; all are now directories of `flutter_testsmith` (`lib/src/<component>/`). The workspace root cannot share a name with a member, so it is `flutter_testsmith_workspace`. The Figma integration was `figma_client` until pub.dev release preparation found that name owned by an unrelated package. Older milestone reports and evidence keep the names as written at the time. |
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
