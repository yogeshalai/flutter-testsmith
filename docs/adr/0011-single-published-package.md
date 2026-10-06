# ADR-0011: One published package, `flutter_testsmith`; boundaries move from packages to imports

**Status:** accepted (2026-10-06). Migration in progress: the engine has moved;
CLI, Figma, AI and protocol have not. The migration order was corrected on
2026-10-06; see "Correction to the order".
**Supersedes, in part:** the package topology of ARCHITECTURE §6, and the
assumption in ADR-0003 that the platform ships as several packages. ADR-0003
itself stands: its decision (directories inside a package, not a package per
module) is the same decision, applied one level up. Neither document is
rewritten; this one says which of their assumptions no longer hold.

## Context

The repository is six packages: `flutter_testsmith` (the in-app SDK),
`flutter_testsmith_protocol`, `flutter_testsmith_engine`,
`flutter_testsmith_cli` (the `testsmith` executable),
`flutter_testsmith_figma` and `ai_client`. Commit 013fb9b prepared all six
for independent publication.

That is not the product a user should meet. Someone testing a Flutter
application wants one line in a pubspec:

```yaml
dependencies:
  flutter_testsmith: ^1.0.0
```

Six packages on pub.dev means six names to find, six versions to keep
compatible, and a page per implementation detail. The protocol, engine,
Figma and AI packages exist to keep the code layered, not because anyone
should depend on them separately.

## The constraint that decides the shape

pub.dev accepts only dependencies it can itself serve:

- *"you cannot upload a package to the pub.dev site if it has any path
  dependencies in its pubspec"* and *"Git dependencies are not allowed"*
  (dart.dev/tools/pub/dependencies);
- a published package should *"depend only on hosted dependencies from the
  default pub package server and SDK dependencies (`sdk: flutter`)"*
  (dart.dev/tools/pub/publishing).

Checked locally (2026-10-06, Dart 3.12.2): `dart pub publish --dry-run` on a
package with a `path:` dependency on a `publish_to: none` package fails with
*"Publishable packages can't have 'path' dependencies"*.

A trap specific to this repository: inside the workspace, a dependency such as
`flutter_testsmith_protocol: ^0.1.1` resolves to the local member whatever its
source (dart.dev/tools/pub/workspaces). The dry-run of 013fb9b therefore passed
with zero warnings while `flutter_testsmith` depended on a package that does not
exist on pub.dev. An application outside the workspace could not have resolved
it.

So a published `flutter_testsmith` cannot keep the other five as dependencies
unless they are published too, which is the six-package outcome this decision
rejects. **The components must live inside the published package.**

## Decision

1. **`flutter_testsmith` is the only package published to pub.dev.** The other
   five become components inside it. Until the migration finishes, all six
   keep `publish_to: none`. It is removed from `flutter_testsmith` alone, as
   the last step.
2. **Components are directories, not packages.** Destinations:

   | Component | Today | After the migration |
   |---|---|---|
   | SDK | `packages/flutter_testsmith/lib/` | unchanged |
   | protocol | `packages/flutter_testsmith_protocol/lib/` | `lib/src/protocol/` |
   | engine | `packages/flutter_testsmith_engine/lib/` | `lib/src/engine/`, public `lib/engine.dart` |
   | CLI | `packages/flutter_testsmith_cli/{lib,bin}/` | `lib/src/cli/`, `bin/testsmith.dart` |
   | Figma | `integrations/flutter_testsmith_figma/lib/` | `lib/src/figma/`, public `lib/figma.dart` |
   | AI | `integrations/ai_client/lib/` | `lib/src/ai/`, public `lib/ai.dart` |

3. **The two layering invariants keep their meaning and change their form.**

## Package-level and library-level boundaries

The old invariants were stated about *dependencies*: `flutter_testsmith` may
not depend on `flutter_testsmith_engine`, and the engine may not depend on
Flutter. Inside one package, a dependency declaration describes the whole
package and cannot separate the SDK from the engine.

What the invariants protected was always about *imports*:

- An application links only the libraries its imports reach. The SDK not
  linking the testing brain is a property of what `lib/flutter_testsmith.dart`
  reaches, not of what the pubspec lists.
- A native CLI and Flutter-free unit tests need the engine's *code* never to
  reach `dart:ui`. A package-level `flutter` dependency does not stop
  `dart compile exe` or `dart test` on a library that never imports Flutter.
  Both were checked locally on a package that depends on Flutter and ships a
  pure-Dart executable.

The invariants are therefore restated over the import graph:

- **Rule A - SDK isolation.** Nothing reachable from
  `lib/flutter_testsmith.dart`, directly or transitively, through any import,
  export, part or conditional-import branch, is engine, CLI, Figma or AI code.
- **Rule B - Flutter-free components.** Nothing reachable from protocol,
  engine, CLI, Figma or AI code is `package:flutter`, `dart:ui`, a package that
  depends on the Flutter SDK, or the SDK component.
- **Rule C - publishable dependencies.** `flutter_testsmith`'s `dependencies:`
  are hosted on pub.dev or come from the Flutter SDK. A dependency on a
  workspace member is *pending*, not wrong, while the migration is under way.

### What is given up

The published package declares every component's dependencies (`vm_service`,
`image`, `args`, `yaml`), so they enter every application's dependency
*resolution* and must be compatible with its other constraints. They are not
compiled into the application unless something imports them, and Rule A
guarantees the SDK does not. This cost is inherent to "one line gives you
everything" and was accepted on 2026-10-06. Flutter 3.44.7's `flutter_test`
pins none of these four.

## Why the CLI can share the package

Checked locally on a package that depends on Flutter and ships a pure-Dart
executable (2026-10-06, Flutter 3.44.7):

- `dart run <pkg>:<exe>` and `flutter pub run` work from a consuming Flutter
  application;
- `dart pub global activate` and `flutter pub global activate` both work;
- `dart compile exe` produces a working native binary;
- pure-Dart tests run under plain `dart test`, alongside `flutter_test`.

The executable only has to keep its import closure free of Flutter, which is
Rule B.

## Intended public API

- `package:flutter_testsmith/flutter_testsmith.dart`: the in-app SDK. Same
  import and same exports as today, including the protocol it re-exports, so
  nothing changes for an application.
- `package:flutter_testsmith/engine.dart`, `figma.dart` and `ai.dart`:
  component libraries replacing today's per-package barrels, for the
  example's validator matrices and anyone scripting the engine.
- The `testsmith` executable: `dart run flutter_testsmith:testsmith`, or
  `dart pub global activate flutter_testsmith`. The CLI's code stays under
  `lib/src/cli/` and is not public API.

How stable the component libraries promise to be (part of 1.0.0, or
documented as experimental) is decided before the first publication, not here.

## Enforcement during the migration

`scripts/check_dependencies.dart` (CI step 1) runs rules A, B and C from
`scripts/import_graph.dart`. It parses directives with the real Dart parser and
resolves `package:` URIs through `.dart_tool/package_config.json`. Each file is
classified by its path against both the legacy and the destination location of
its component, so the rules hold before the first move, after each one, and after
the last. Nothing about the future layout is assumed to exist.

| After | Rule A | Rule B | Rule C pending (default: reported; `--release`: failure) |
|---|---|---|---|
| this ADR (no moves) | enforced: SDK + protocol packages | enforced: five legacy packages | 7: protocol dependency; five components outside; `publish_to` |
| engine moved (**done**) | enforced; `lib/src/engine/` and `lib/engine.dart` are engine code | enforced; engine at its destination | 8: protocol, Figma and AI dependencies; four outside; `publish_to` |
| CLI moved | enforced; `bin/` is CLI code | enforced | 7: those three dependencies; three outside; `publish_to` |
| Figma moved | enforced | enforced | 5: protocol and AI dependencies; two outside; `publish_to` |
| AI moved | enforced | enforced | 3: protocol dependency; protocol outside; `publish_to` |
| protocol moved | enforced; protocol under `lib/src/protocol/` | enforced | 1: `publish_to` only |
| `publish_to` removed | enforced | enforced | nothing; `--release` passes |

The pending count rises after the engine move, and that is correct: the engine
brought its dependencies on the Figma and AI packages into `flutter_testsmith`,
and each disappears when that package moves in.

The original package-level rules keep running while their packages exist. A
legacy package that has disappeared is accepted only when its component is
found at its destination; otherwise it is still reported missing.

## Migration strategy

One commit per step, full verification after each, no behaviour change. Each
step also updates whatever it invalidates: the example application, the root
tests, the local registry, CI and the documentation.

1. this ADR, `publish_to: none` restored on all six, and the guard (2496d07);
2. move the engine; add `lib/engine.dart`. Its tests go to `test/engine/`, and the
   SDK's tests to `test/sdk/` so that each suite still runs on its own (**done**);
3. move the CLI; add `bin/testsmith.dart` and `executables:`;
4. move Figma;
5. move AI;
6. move the protocol;
7. documentation, version, and `publish_to` removed from `flutter_testsmith`.
   `check_dependencies.dart --release` must pass.

### Correction to the order (2026-10-06)

This ADR first listed the protocol to move first, then AI and Figma, then the
engine. That order cannot be executed without breaking a rule that is still in
force. Moving component X inside `flutter_testsmith` has two effects:
`flutter_testsmith` takes on X's dependencies, and every package still outside
that uses X must depend on `flutter_testsmith`.

- Protocol, Figma or AI first: the engine package uses all three, so it would
  have to depend on `flutter_testsmith`. The package-level rule "the engine
  never depends on `flutter_testsmith`" forbids that while the engine package
  exists.
- CLI first: `flutter_testsmith` would have to depend on the engine package,
  which the rule "`flutter_testsmith` never depends on the engine" forbids.
- **Engine first: no rule is broken.** `flutter_testsmith` takes on Figma, AI and
  the protocol, which no rule forbids. The CLI package, still outside, depends
  on `flutter_testsmith`, which no rule forbids either, and rule B still proves
  the CLI's code reaches no Flutter.

After the engine, every order is legal; the protocol goes last because every
other component uses it. No rule was weakened to allow the corrected order.

## Alternatives considered

**Publish all six; users add only `flutter_testsmith`.** Pub would resolve the
rest transitively. Rejected: six packages on pub.dev is the experience this
decision exists to avoid, and the SDK would still need the engine and CLI to give
"everything" from one line, which breaks the package-level invariant anyway.

**A new facade package depending on unpublished internals.** Not publishable:
see the constraint above.

**Keep six packages for development and assemble one package at release.**
Rejected: what is published would differ from what is in the repository and what
is tested, pub.dev's repository check would point at code that differs from the
archive, and rewriting imports at release time is fragile.

**Flatten everything into one `lib/src/`.** Rejected for the reason ADR-0003
rejected it for the engine: it loses the separation the rules above depend on.
