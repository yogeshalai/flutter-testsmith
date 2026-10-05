# ADR-0002: Dart VM Service as the primary transport

**Status:** Accepted
**Date:** 2026-09-10

## Context

The runner needs a bidirectional channel to the running app for navigation
events, UI tree snapshots, network events, screenshots and logs.

## Decision

Use the Dart VM Service as the Phase 1 transport, behind an `SdkTransport`
interface. The SDK registers service extensions (`ext.mytest.*`) and streams
events via `dart:developer`; the runner discovers the WebSocket URI from
`flutter run --machine`.

## Rationale

- **One transport, every platform.** Android, iOS, desktop and web behave
  identically. No adb dependency for the data channel.
- **Full fidelity.** Direct in-process access to the element tree, render
  geometry and the semantics tree - everything the UI inspection requirement
  needs.
- **No listening socket in the app.** An embedded server needs a port,
  INTERNET permission and port forwarding, and is a standing production
  hazard. The VM Service does not exist in release builds at all.
- **Proven.** This is exactly how Flutter DevTools works.

## Verified capabilities (measured 2026-09-10, Dart 3.12.2)

Probed with a throwaway spike rather than assumed. Results:

| Capability | Result |
|---|---|
| Custom extension registration (`registerExtension`) | Works |
| RPC round-trip with args and JSON response | Works |
| Runner-side discovery via `isolate.extensionRPCs` | Works |
| Structured JSON events via `extensionData` | Works |
| `postEvent` with no DDS | **0 of 50 pre-subscription events delivered** |
| `postEvent` with DDS (the default) | **50 of 50 replayed, in order** |
| DDS replay capacity | **Exactly 10,000 events per stream**, ring-dropped oldest-first (20,000 emitted, seq 10000-19999 delivered) |

Two conclusions follow.

**The ring buffer is still required.** DDS replay is an undocumented
implementation detail of a host tool, absent under `--no-dds` or on a direct
VM Service connection, and free to change between releases. The handshake
drain is the protocol-guaranteed mechanism; DDS replay is a coincidence we
must not depend on.

**Duplicate delivery is certain, not hypothetical.** Because DDS replay and
the handshake drain both deliver the same startup events, every event emitted
before attach arrives twice. The engine therefore **deduplicates by
`eventId`, preserving first-seen order**. This is cheap only because
`eventId` is already in the envelope; discovered later it would have
presented as duplicated screen transitions with no obvious cause.

## Consequences

VM Service requires a debug or profile build. Release-mode and device-farm
execution will eventually need a second transport (risk R13) - which is why
`SdkTransport` is an interface from day one rather than a concrete class.

`postEvent` is fire-and-forget, so events emitted before the runner subscribes
are lost. This forces the SDK-side ring buffer drained by `handshake`
(ARCHITECTURE 8.1) - a consequence worth stating because it is easy to miss
until the first screen of every run turns out to be racy.

## Alternatives considered

**Embedded WebSocket server in the SDK.** Works in release builds and is
transport-uniform. Rejected as the *primary*: it reimplements what the VM
Service already provides, needs port forwarding and INTERNET permission, and
puts a listening socket inside a shipped application. Retained as the planned
second implementation for release-mode use.

**flutter_driver / integration_test.** Rejected: the specification explicitly
excludes wrapping an external E2E framework as the core engine, and the driver
script would run on-device, which is the wrong place for our engine.
