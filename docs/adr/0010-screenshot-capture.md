# ADR-0010: Two screenshot capture paths, and what each one is for

**Status:** accepted (Phase 12)
**Supersedes nothing. Retires:** risk R5.

## Context

The protocol has carried `ScreenshotSource.repaintBoundary` since Phase
1, and until Phase 12 nothing had ever produced one. Every screenshot -
the smoke images, the committed visual baseline, every comparison in
Phase 7 - came from `adb exec-out screencap`.

Risk R5 said the two paths "do not produce identical images" and that
`RepaintBoundary` would be "the default for design comparison". Neither
half of that had been tested, because the second path did not exist.

The brief for Phase 12 asks, precisely: what does each path capture,
what does it exclude, what coordinate system does it produce, how does
it handle `devicePixelRatio`, is it suitable for design comparison, and
is it deterministic across runs.

## What each path captures

| | `screencap` | `surface` |
|---|---|---|
| **Mechanism** | `adb exec-out screencap -p` | `ext.mytest.screenshot` → `OffsetLayer.toImage` on the root layer |
| **Runs** | on the host, through adb | in the application's own process |
| **Contains** | the real framebuffer | only what Flutter painted |
| **Status bar** | yes | no |
| **Navigation bar** | yes | no |
| **System dialogs, toasts, IME** | yes | no |
| **Another app's window over ours** | yes | no |
| **Platform views** (WebView, map, camera) | yes | **no - a hole in the image** |
| **Screen brightness, night mode, colour filters** | applied | not applied |
| **Geometry** | the panel's resolution, after any OS scaling | exactly `logical size x devicePixelRatio` |
| **Transfer** | binary over adb | base64 JSON over the VM Service |

Measured on the SM-M127G: `screencap` gives **720x1600** and 56,286
bytes; `surface` gives **720x1510** and 49,200 bytes - the same width,
and 90 rows shorter, which is the status bar plus the navigation bar.

### Coordinate system

Both produce **physical pixels**. `RenderView.paintBounds` is already in
physical pixels - the root layer's transform carries the device pixel
ratio - so the surface path rasterises at scale 1 and no second ratio
enters the arithmetic. That is deliberate: the R3b bug was a ratio read
at the wrong moment, and the fewer places a ratio appears, the fewer
places it can be read at the wrong moment.

The UI tree reports **logical** pixels. Converting between the two uses
the ratio recorded in the same snapshot as the bounds - see ADR-0006 -
and that is unchanged by this decision.

### devicePixelRatio

The surface path reads the ratio from `RenderView.configuration` at
capture time and reports it in the reply, so a consumer never has to
assume. A caller may override it to rasterise at a different scale; the
platform never does, because a resampled image compared against a
baseline measures the resampler.

## Is it deterministic?

Yes, and this was measured rather than assumed.

- **In `flutter_test`**, consecutive captures of an unchanged tree are
  **byte-identical** (`surface_capture_test.dart`). A changed tree
  produces different bytes.
- **On the SM-M127G**, two full runs against a recorded surface
  baseline reported **0.000% of 1,011,600 pixels differing, ssim
  1.0000**, each a fresh install and launch.
- **On the SM-M127G**, five full runs of the same unchanged screen,
  each a fresh install and launch, reported **0.000% of 1,076,400
  pixels differing, ssim 1.0000** - after ignoring the two system bars.
  Before ignoring the navigation bar it was a constant 0.065%, which is
  a property of `screencap`, not of the surface path.

Determinism is not the same as portability. A baseline is tied to the
resolution it was recorded at, and comparing across devices is refused
rather than resampled - see "What is still not true" below.

## Is it suitable for design comparison?

**No, and neither path is.** This is the part most worth being plain
about.

The surface path removes the system chrome, the OS scaling and the
platform-view holes. What it does not remove is the reason risk R7
exists: **Figma and Flutter do not rasterise text the same way.**
Different hinting, different subpixel positioning, different metrics.
An exported Figma frame and a Flutter surface capture of a *correct*
implementation differ by far more than any tolerance worth having.

So the split established in Phase 6 and Phase 7 stands, unchanged:

- **Figma is the authority for structure** - presence, element kind,
  geometry, ordering, typography and colour - compared **numerically**
  against the captured UI tree, never against pixels.
- **Screenshots are compared with a previously accepted screenshot of
  the same screen on the same device**, which is a regression check and
  not a design check.

Phase 12 measured the whole Figma comparison against a real device and a
real design: 47 structural checks on `/product/details`, 26 on
`/checkout`, all deterministic, none of them looking at a pixel. That
capability is real. **Pixel-perfect Figma comparison is not, and this
platform does not claim it.**

The surface path does make design comparison *less bad* in one specific
way - the image now contains exactly the region the design describes,
with no status bar occupying rows the frame knows nothing about. That
matters if anyone ever builds an advisory overlay. It does not make the
comparison authoritative.

## Decision

Ship both. Record which path produced each image. **Refuse to compare
across paths.**

The refusal is the load-bearing part. A `repaintBoundary` image and a
`screencap` of the same screen are not two qualities of one picture,
they are two different pictures; diffing them reports a change that
never happened, and a check that reports changes that never happened
gets switched off.

`screencap` stays the **default**, for three reasons:

1. Every committed baseline in this repository was recorded with it, and
   a default that silently invalidated them would be a trap.
2. It is the only path that sees a system dialog, a permission prompt or
   a crash overlay sitting on top of the application - which is
   precisely the class of bug an end-to-end test exists to catch.
3. It needs nothing of the application. The surface path requires an SDK
   new enough to serve the RPC, and the runner checks the handshake
   capability before asking.

`surface` is opted into per screen:

```yaml
visual:
  capture: surface
```

and the runner **errors** rather than falling back if the application
cannot serve it, because a silent substitution would be compared against
a baseline recorded the other way.

## What is still not true

- **A baseline is tied to one device resolution.** Running
  `/product/details` on the AVD against the physical device's baseline
  reports *"the screenshots are different sizes: baseline is 720x1600,
  this run captured 1080x2400. Nothing was compared."* That is the right
  answer and not a useful one; baselines keyed by device profile are the
  obvious next step, and the per-fixture variant added in Phase 12 is
  the mechanism to extend.
- **The surface path ships a base64 PNG through the VM Service.**
  Measured at 720x1510 the payload is tens of kilobytes, which is fine.
  A tablet at 3x is a different proposition and has not been measured.
- **Ignore regions belong to a capture path, not to a screen.** The
  example's two regions mask the status and navigation bars of a
  `screencap`. Switching that screen to `surface` and changing nothing
  else masks 105 rows of real content instead - measured: the compared
  pixel count fell from 1,087,200 to 1,011,600. Nothing warns about
  this. It is the sharpest edge the two-path design leaves behind.
- **Platform views are invisible to it.** An application whose screen is
  mostly a `WebView` gets a picture of a hole. Nothing warns about this,
  because nothing in the tree distinguishes a platform view yet.
