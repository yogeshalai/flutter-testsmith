# E-01 — External SDK consumption

How an application that is not in this repository adds the test SDK, and
why that needed a change on the platform's side rather than a note in a
README.

---

## 1. The packaging problem

`flutter_testsmith` could not be added to any application outside this monorepo.
That was recorded as finding **E-01** during the external-application
milestone and worked around rather than fixed; this document is the fix.

The symptom, verbatim:

```
Because every version of flutter_testsmith from path depends on flutter_testsmith_protocol any
which doesn't exist (could not find package flutter_testsmith_protocol at
https://pub.dev), flutter_testsmith from path is forbidden.
```

The cause is one fact about `pub`, which was measured rather than assumed:

> **A package fetched from repository X has its own dependencies resolved
> from the _default_ repository, not from X.**

`flutter_testsmith` declares `flutter_testsmith_protocol: ^0.1.0`. That constraint is correct —
it is exactly what the package would publish to pub.dev. But a consumer
resolving `flutter_testsmith` from anywhere other than the default repository still
looks for `flutter_testsmith_protocol` on pub.dev, finds nothing, and fails version
solving outright.

This was verified directly, with a throwaway repository and two synthetic
packages:

| Probe | Result |
|---|---|
| Transitive dependency of a package served from a private repository | resolved from **pub.dev** — reproduces E-01 exactly |
| Parent declares the dependency with an explicit `hosted: url:` | resolves |
| Clean pubspecs, consumer points `PUB_HOSTED_URL` at a repository that proxies pub.dev | resolves, and public packages still resolve |
| `resolution: workspace` / `publish_to: none` inside a _fetched_ package | tolerated; pub ignores both for non-root packages |

The consequence is that **there is no consumer-side flag that fixes
this**. Either the consumer names `flutter_testsmith_protocol` itself — which is the
workaround that was in `external_app`, and which forces every application to
know an internal platform package — or `flutter_testsmith_protocol` is reachable from
the repository the consumer is already resolving against.

A second, quieter half of the same problem: fourteen `flutter_testsmith_protocol` types
appeared in `flutter_testsmith`'s **public API** (`TestSdk.initialize` takes an
`AppContext`, the tree inspector returns a `UiSnapshot`, the channel
carries a `TestEvent`) and none of them were re-exported. Even with
resolution fixed, an application would have had to add `flutter_testsmith_protocol` to
its own pubspec just to _name_ those types.

---

## 2. Dependency graph — before

```
external_app (external application)
│
├── dependencies:
│     flutter_testsmith ─────────── path: ../flutter-ai-test-platform/packages/flutter_testsmith
│
└── dependency_overrides:            ← required, or nothing resolved at all
      flutter_testsmith ─────────── path: ../flutter-ai-test-platform/packages/flutter_testsmith
      flutter_testsmith_protocol ────── path: ../flutter-ai-test-platform/packages/flutter_testsmith_protocol
                                     ↑
                     the application names an internal platform package,
                     and pins the platform's directory layout as a sibling
                     of its own checkout
```

Properties: the application could only build if the platform repository
was cloned next to it, at that exact relative path. It named a package it
does not use. Both packages resolved as `source: path`.

## 3. Dependency graph — after

```
external_app (external application)
│
└── dependencies:
      flutter_testsmith: ^0.1.0                      source: hosted, direct main
            │
            └── flutter_testsmith_protocol: ^0.1.0       source: hosted, TRANSITIVE
                                            the application never names it
```

Resolved from `external_app/pubspec.lock` after the change:

```yaml
  flutter_testsmith:
    dependency: "direct main"
    source: hosted
    version: "0.1.0"
  flutter_testsmith_protocol:
    dependency: transitive        # ← the fix, in one word
    source: hosted
    version: "0.1.0"
```

`source: path` appears **zero** times. Nothing in the application refers to
the platform's directory layout.

### The platform's internal direction, unchanged

```
        flutter_testsmith_protocol          no dependency but `meta`
         ↑         ↑           the contract both sides share verbatim
         │         │
     flutter_testsmith   flutter_testsmith_engine    SDK: in-app, links Flutter
         │         ↑           engine: out-of-process, MUST NOT link Flutter
         │         │
    (application) flutter_testsmith_cli
```

Arrows point _towards_ the dependency. The two long-standing rules —
`flutter_testsmith` must not depend on `flutter_testsmith_engine`, and `flutter_testsmith_engine` must not
depend on Flutter — are unchanged and still enforced by
`scripts/check_dependencies.dart`.

---

## 4. Package boundaries

| Package | Consumed externally? | Why |
|---|---|---|
| `flutter_testsmith` | **yes** — the only package an application names | In-app instrumentation. Linked into the application under test. |
| `flutter_testsmith_protocol` | **yes, but never named** | Arrives transitively through `flutter_testsmith`, which also re-exports it. |
| `flutter_testsmith_engine` | no | Runs out of process. Linking it into an application would put the testing brain inside the thing under test. |
| `flutter_testsmith_cli` | no | The `testsmith` runner. A developer tool, not a dependency. |
| `figma_client` | no | Engine-side. Reaches the network for designs. |
| `ai_client` | no | Engine-side. Holds provider credentials. |

Two rules now hold mechanically, checked by
`scripts/check_dependencies.dart` and by `test/packaging_test.dart`:

1. **No reach-back.** `flutter_testsmith` and `flutter_testsmith_protocol` may declare no `path:`
   or `git:` dependency. Such a dependency cannot be resolved by an
   application that fetched the package from a repository — which is E-01
   restated as a rule. `dev_dependencies` are exempt: they are never
   resolved for a consumer.

2. **A closed public surface.** Every `flutter_testsmith_protocol` type reachable
   through `flutter_testsmith`'s public API is re-exported by `flutter_testsmith`. This is
   asserted by `packages/flutter_testsmith/test/public_surface_test.dart`, which
   imports _only_ `package:flutter_testsmith/flutter_testsmith.dart` and passes by
   compiling.

`flutter_testsmith` therefore re-exports `flutter_testsmith_protocol` wholesale. It is the
single app-side surface: one import to write, one package to version.

---

## 5. How an external Flutter application consumes the SDK

In the application's `pubspec.yaml`:

```yaml
dependencies:
  flutter_testsmith: ^0.1.0
```

That is the whole declaration. It is byte-identical to what the
application would write if `flutter_testsmith` were on pub.dev. There is no
`dependency_overrides`, no path, and no mention of `flutter_testsmith_protocol`.

In the application's entry point, before `runApp`:

```dart
import 'package:flutter_testsmith/flutter_testsmith.dart';

await TestSdk.initialize(
  appId: 'com.example.app',
  appVersion: '1.0.0',
  // A compile-time constant: a release build tree-shakes the
  // instrumentation away entirely, and a normal build is byte-identical
  // to one without this call.
  config: const TestSdkConfig(enabled: bool.fromEnvironment('TEST_MODE')),
);
```

Instrumentation is **off unless explicitly enabled**. The runner passes
`--dart-define=TEST_MODE=true` itself; nothing else does.

---

## 6. Local / private development workflow

`flutter_testsmith` is not on pub.dev and is not going there in this milestone. It
is served from a private package repository on the loopback interface.

```bash
# In the platform repository. Leave it running.
dart run scripts/serve_local_registry.dart --port 8123
```

The repository serves `flutter_testsmith` and `flutter_testsmith_protocol` from archives built
out of the version-controlled file list, and **302-redirects everything
else to pub.dev**. That redirect is what makes it usable as a default
repository: an application still resolves its other ~260 packages
normally.

```bash
# In the consuming application.
PUB_HOSTED_URL=http://localhost:8123 flutter pub get
```

To inspect exactly what a consumer downloads, without serving it:

```bash
dart run scripts/serve_local_registry.dart --out build/local_registry
```

Nothing here publishes anything publicly. Both packages keep
`publish_to: none`, and the repository binds to loopback only.

---

## 7. Build commands

```bash
# Platform: the boundary rules, then the suites.
dart run scripts/check_dependencies.dart
dart analyze                                  # CI runs --fatal-infos
dart test test/local_registry_test.dart test/packaging_test.dart
dart test test/external_consumer_test.dart    # a real external Flutter app

# Application: resolve and build against the private repository.
export PUB_HOSTED_URL=http://localhost:8123
flutter pub get
flutter build apk --debug -t lib/main_mytest.dart --flavor <flavor>
```

## 8. Runtime commands

```bash
export PUB_HOSTED_URL=http://localhost:8123

# One flow.
dart run packages/flutter_testsmith_cli/bin/testsmith.dart run <app>/mytest/tests/home.yaml \
    --app <app> -d <serial> --mock-api 8080 \
    -t lib/main_mytest.dart --flavor <flavor> --out out/home

# The deterministic suite.
./scripts/run_e2e.sh --device <serial>
```

---

## 9. Known limitations

1. **The application cannot resolve without the repository running.**
   `flutter_testsmith` is imported by production sources, so it is a regular
   dependency, and an unpublished regular dependency is unresolvable by
   definition. Until the SDK lives on a durable registry, a developer who
   has not started `serve_local_registry.dart` cannot run `flutter pub get`
   at all. This is inherent to consuming an unpublished package, not a
   property of this design.

2. **The lockfile records the repository URL for every package.**
   `PUB_HOSTED_URL` is a default for the whole resolution, so all 265
   entries in `external_app/pubspec.lock` name `http://localhost:8123`. This
   is what a private registry genuinely looks like — an organisation using
   Artifactory or Cloudsmith has exactly this in its lockfiles — but the
   URL is machine-specific here, so the committed lockfile is only
   meaningful to someone using the same port. Pointing the repository at a
   durable internal hostname removes the problem entirely.

3. **A per-dependency `hosted:` block does not work.** Pointing only
   `flutter_testsmith` at the repository leaves `flutter_testsmith_protocol` resolving against
   pub.dev, and version solving fails. This was measured, not assumed. The
   default-repository redirect is the only mechanism that keeps the
   consumer's pubspec free of internal package names.

4. **Archive contents come from `git ls-files`.** A file that is not
   tracked will not reach a consumer, even though it is present in the
   working tree and a path dependency would have used it. This matches
   what `dart pub publish` does with a git checkout, and
   `test/packaging_test.dart` asserts that every source named by
   `flutter_testsmith`'s public exports is actually in the archive.

5. **Test configuration still lives in the application directory**
   (`mappings/`, `mock_api/`, `mytest/tests/`, `visual_baselines/`). That
   is finding E-09, and it is untouched here.

---

## 10. What would still be required before a public release

Nothing in the dependency graph — both pubspecs are already in their
publishable form, which is the point of choosing a repository over a git
or path mechanism. What remains is publication hygiene:

1. **Remove `publish_to: none`** from `flutter_testsmith` and `flutter_testsmith_protocol`. It
   is deliberately still there: it is the safety rail that makes an
   accidental `pub publish` impossible.
2. **Remove `resolution: workspace`** from both, or publish through a tool
   that strips it. Pub tolerates the key in a fetched dependency —
   verified — but it has no meaning outside this repository.
3. **Add `LICENSE` and `CHANGELOG.md`** to each package, and run
   `dart pub publish --dry-run` to clear the remaining publication
   validators (description length, example, documentation links).
4. **Decide the versioning contract.** `flutter_testsmith_protocol` carries a
   `ProtocolVersion` whose major component decides compatibility; that is
   independent of the pub version, and the relationship between the two
   needs stating before anyone outside can rely on either.
5. **Widen the SDK constraint deliberately.** `flutter_testsmith` requires
   `sdk: ^3.12.0` and `flutter: >=3.24.0`. Published, that becomes a
   promise to consumers.
6. **Reconsider the wholesale protocol re-export.** Re-exporting all of
   `flutter_testsmith_protocol` closes the surface with one line, but it also publishes
   engine-facing types (envelopes, handshakes) into the application's
   namespace. Before a public release this is worth narrowing to the types
   that actually appear in the SDK's API.

Publishing is **not** part of this milestone.
