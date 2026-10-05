# ADR-0007: Width-fit projection, and skipping vertical checks

**Status:** Accepted
**Date:** 2026-09-11

## Context

Structural comparison has to decide whether a Flutter element is where
the design says it should be. The two coordinate spaces never agree.

The `Product Details` frame this was built against is **402 x 1198**.
The device it was first run on (SM-M127G) reports a **384 x 805**
viewport. Comparing the raw numbers reports every element on the screen
as misplaced, which is worse than not checking: a validator that always
fails is one people turn off.

Two mismatches are tangled together here, and they are not the same
problem.

1. **Scale.** The design is drawn at one width; the device has another.
   This is a pure conversion and is solvable exactly.
2. **Shape.** A 402x1198 frame is not a viewport at all - it is a
   scrolling page captured whole, with an aspect ratio of 2.98 against
   the device's 2.10. No single scale factor reconciles the two, because
   the design describes content that does not fit on screen at once.

A third mismatch was found only by running on hardware, and it is the
one that actually bit. The first implementation took the screen size
from `UiSnapshot.root.bounds`. That root is **synthetic** - the union of
the retained nodes - so it is smaller than the display whenever content
stops short of the edges and larger whenever something overflows. On
`/home` it measured `384x521` on an `384x805` screen; on the product
screen it measured `480x791`. Every coordinate was then scaled by the
wrong factor, and a pixel-accurate layout was reported as 20% out.

## Decision

Take the screen size from a new `UiSnapshot.viewport`, reported by the
SDK from the `RenderView`, and **never** from the synthetic root. Where
an app is on an SDK too old to send it, geometry is reported as skipped
with that reason; the root bounds are not substituted, because a
plausible-looking wrong answer is worse than an honest absence.

Then scale **by width**, in `DesignProjection.fitWidth`.

Designs are authored to a canvas width and expected to grow vertically.
Fitting by height instead would shrink every horizontal measurement on
any design longer than the viewport, which is most of them.

Then treat the shape mismatch separately: when the aspect ratios differ
by more than a configurable fraction (`aspectDelta`, default 5%),
**vertical position checks are reported as `skip`, while horizontal
position and size checks still run.**

## Consequences

A design taller than the viewport still gets its x, width and height
compared - which is where most real layout defects live - and says
plainly that y was not compared and why:

```
- figma-geometry: vertical positions were not compared: the design frame
  is 402x1198 and the viewport is 384x805, an aspect difference of 30%.
  Horizontal position and size are still checked.
```

The alternative - comparing y anyway and widening `positionPx` until it
passed - would have required a tolerance of several hundred pixels,
which is not a tolerance but a disabled check wearing one as a disguise.

Vertical *ordering* is unaffected and still checked
(`figma-order`), because relative order survives both scaling and scroll
offset. On a screen where absolute y cannot be compared at all, ordering
is what still catches a swapped layout.

Anchoring offsets (`originDx`, `originDy`) exist for the narrower case
of a design drawn without the status bar the device actually has. They
are not a substitute for the aspect check: an offset shifts everything
uniformly, and a shape mismatch does not.
