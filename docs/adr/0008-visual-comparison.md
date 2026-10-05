# ADR-0008: Two gates, measured per element, against a committed baseline

**Status:** Accepted
**Date:** 2026-09-11

## Context

Risk R6 says a visual check that cries wolf gets disabled, and makes a
*measured* false-positive rate the exit criterion rather than an
assumed one. Risk R7 says a Figma export and a device screenshot cannot
be pixel-equal, so Figma stays the authority for structure (Phase 6)
and pixel comparison is baseline-to-baseline.

That leaves the question of what "different" means. Three things were
learned by measuring rather than by reasoning.

**A per-channel threshold of zero is unusable.** Antialiasing, font
hinting and GPU rounding move channels by a few units between otherwise
identical runs.

**Mean SSIM is size-sensitive.** It is an average over 8x8 windows, so
what one changed area costs depends on how many windows the image has.
A single stray pixel drags a 100x100 image to 0.9938 and a 1080x2400
image to 0.99998 - a factor of 300. Any threshold tight enough to mean
something on a small image fails constantly on a large one.

**A whole-screen ratio cannot see a small element.** The seeded price
regression changed 15.6% of the price element and 0.04% of the screen.
Against a whole-screen tolerance of 0.2% it is invisible; against the
element's own area it is unmistakable.

## Decision

**Three gates, each with its own threshold.** The whole-screen pixel
ratio (0.2%) catches large localised change. The per-element ratio
(5% of the element's own area) catches a small element changing. Mean
SSIM (0.98, deliberately loose) is a coarse backstop for structural
change spread so thinly that no individual pixel crosses the channel
threshold - what a font substitution looks like.

**An element wholly off-screen is not a failure.** On a scrolling page
most content is below the fold; failing for that fails identically on
every run, which is the definition of a false positive. It is reported
as "not compared" so a reader can tell that from "compared and
matched". An element that is *partly* visible is compared on the part
that is visible. Had an element moved off-screen from a position it
used to occupy, the pixels it vacated would change and the ratio gate
would catch that.

**A size change is its own outcome.** Comparing a 1080-wide baseline
with a 720-wide capture row by row produces a number that means
nothing.

**The capture path is recorded and never mixed.** A `RepaintBoundary`
image has no status bar and a `screencap` does. Diffing across the two
reports a change that never happened, so the store refuses.

**Baselines are committed files and are never updated automatically.**
A first run records and reports `skip` - it cannot detect a regression
and must not claim to have. A differing run leaves the baseline alone:
a store that re-records on difference is a suite that can never fail
the same way twice. `--update-visual-baselines` is explicit, and its
help text says it accepts whatever is on screen, including a
regression.

## Consequences

Measured on an SM-M127G, after ignoring the status bar:

| | result |
|---|---|
| Three identical runs | 0.000% differing, ssim 1.0000, **0 false positives** |
| Seeded price regression | caught: `product.price differs by 15.552% of its own area` |

The status bar mattered. Before it was ignored, ~480 pixels differed on
every run - the clock and the battery icon - for a stable 0.042%. That
passed, but it spent a fifth of the tolerance budget on something that
is never a regression, and it would have masked a real change of
similar size. Ignore regions are configured in logical pixels so one
setting survives a device of a different density.

The capture path used here is `deviceScreencap`, which is why the
status bar is in the image at all. R5 anticipates a `RepaintBoundary`
capture as the default for *design* comparison; it is not built yet.
Recording the source in the baseline metadata means adding it later
will refuse to compare against these baselines rather than silently
diffing two different pictures.
