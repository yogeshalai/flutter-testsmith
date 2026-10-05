# ADR-0003: One `flutter_testsmith_engine` package, not six

**Status:** Accepted
**Date:** 2026-09-10

## Context

The specification proposes `engine/{device, interaction, navigation, runtime,
validation, reporting}` as the engine's structure, which reads naturally as
six packages.

## Decision

One `flutter_testsmith_engine` package. Those modules become directories under
`lib/src/`, with the package's public surface defined by a single barrel file.

## Rationale

Dart package boundaries are heavyweight: each needs its own `pubspec.yaml`,
version, dependency declarations, publish story and CI wiring. Six packages
means six of each, plus inter-package version constraints to keep in step on
every change - all before a single line of behaviour is written.

Directory boundaries with an explicit barrel give what actually matters:
separated concerns, independent testability, and a reviewable public surface.

The modularity is not lost, only deferred. Because the barrel defines the
public surface, any module can later be extracted into a real package without
touching a single import site at the call sites.

## Consequences

**Weaker enforcement.** Nothing mechanically prevents `reporting/` importing
`device/` internals. Mitigated by the barrel convention (`src/` is private)
and by code review. If this erodes in practice, extraction is the remedy.

**Coarser versioning.** The engine versions as a unit. This is correct for now
- the modules change together during active development anyway.

The two dependency rules that genuinely matter are enforced mechanically by
`scripts/check_dependencies.dart` instead: `flutter_testsmith` must not depend on
`flutter_testsmith_engine`, and `flutter_testsmith_engine` must not depend on Flutter.

## Alternatives considered

**Six packages as specified.** Maximum enforcement, high ceremony. Rejected as
premature for a codebase with no consumers yet.

**One package, no `src/` subdirectories.** Rejected: loses the conceptual
separation the specification asks for, for no gain.
