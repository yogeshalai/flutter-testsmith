# ADR-0006: OS-level adb input with engine-side element resolution

**Status:** Accepted
**Date:** 2026-09-10

## Context

Test steps address elements semantically (`tap: {id: product.add_to_cart}`),
but the act of tapping can happen at two very different layers.

**OS-level (adb):** `adb shell input tap x y`. Real input events through the
real system input stack. Coordinates only - no element awareness.

**In-process:** synthesise pointer events through Flutter's binding via an SDK
RPC. Element-aware, deterministic, platform-agnostic - but bypasses the OS
input stack entirely.

## Decision

`AdbDeviceController` (OS-level) is the Phase 1 implementation and remains the
default for Android. Element awareness is supplied by the **engine**, not the
controller: resolve element ID -> bounds from the UI tree -> tap the centre.

`InProcessDeviceController` is planned for desktop and web, where no adb
equivalent exists.

## Rationale

Layering element resolution above a coordinate-based controller gives both
properties instead of trading one for the other: tests stay semantic, while
the input itself remains real.

Real input matters for correctness of the test itself. An in-process
synthesised tap is delivered directly to Flutter's gesture arena, so it will
happily "tap" a button covered by a system dialog, an ad overlay, or a
mis-positioned sibling. A real tap is intercepted, exactly as a user's would
be - the class of bug an end-to-end test exists to catch.

adb also provides what in-process cannot: real hardware back button, app
install and launch, and device-level screenshots.

## Consequences

**The coordinate-space rule.** UI tree bounds are Flutter *logical* pixels;
`adb shell input` takes *physical* pixels. The SDK reports `devicePixelRatio`
in the handshake, and **every** conversion goes through one function - ad-hoc
multiplication at call sites is prohibited.

This is validated by device choice rather than left to discipline: the test
device (Samsung SM-M127G, 300dpi) has DPR **1.875**, so any conversion error
produces a visibly wrong tap position. A 2.0-ratio device would let whole
classes of mistake pass unnoticed.

**Element resolution needs a fresh UI tree**, so a tap is a two-step operation
(fetch tree, then tap). Stale-bounds races after animation are handled by
settle detection before resolution.

**adb is slower** than in-process synthesis - tens of milliseconds per action.
Acceptable, and honest about what real input costs.

**Android-specific for now**, but behind `DeviceController`, so iOS and
desktop are implementations rather than a redesign.

## Alternatives considered

**In-process input as the default.** Faster, deterministic, cross-platform.
Rejected as the default because it cannot detect overlay interception - it
would report a pass on a screen a real user could not use.

**Both, chosen per step.** Rejected as premature. The interface permits it
later; introducing two input semantics before either is proven would make
failures harder to reason about, not easier.
