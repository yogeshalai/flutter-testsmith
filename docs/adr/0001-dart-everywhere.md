# ADR-0001: Dart for every layer

**Status:** Accepted
**Date:** 2026-09-10

## Context

The platform needs an in-app SDK (necessarily Dart/Flutter) and an
out-of-process engine, CLI, validation core, visual comparison and AI
integration. The engine could be written in any language.

The two sides exchange a rich, evolving event protocol. Whatever language the
engine uses, both sides must agree exactly on every event's shape.

## Decision

Dart for the SDK, protocol, engine and CLI.

## Rationale

The protocol decides it. `flutter_testsmith_protocol` is consumed **verbatim** by both
sides: one definition of every event, no mirrored models. In a split-language
stack the schema must be hand-mirrored or code-generated across a language
boundary, and that boundary is the most likely long-term source of silent
bugs in a system whose entire purpose is comparing values.

Supporting reasons:

- `vm_service` is a first-party Dart package.
- Flutter developers already have the toolchain; no extra runtime to install.
- `dart compile exe` produces a single native `testsmith` binary.
- One language means one lint config, one test runner, one CI setup.

## Consequences

**Accepted costs.** Image processing uses the pure-Dart `image` package
rather than `sharp` or OpenCV - adequate for pixel and SSIM comparison,
mitigated with isolates and downscaling (see risk R15). HTML reporting is
string templating rather than a component framework. Neither Figma nor Claude
has a first-party Dart SDK, but both are plain REST/JSON, so nothing is lost.

**Escape hatch.** If pure-Dart image comparison proves too slow, an
out-of-process native comparator behind the existing comparison interface is
an implementation change, not a redesign.

## Alternatives considered

**Dart SDK + TypeScript engine.** Best ecosystem for visual diff (`sharp`,
`pixelmatch`) and AI SDKs. Rejected: duplicated protocol models plus a Node
runtime dependency for every user.

**Dart SDK + Python engine.** Strongest image and AI tooling. Rejected for the
same protocol-duplication reason, plus a Python runtime that Flutter
developers are least likely to already have.
