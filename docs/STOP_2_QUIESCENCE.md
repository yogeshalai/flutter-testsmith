# STOP-2: screens that never settle

**Status:** implemented.
**Scope:** quiescence only. No Figma, no autonomous AI, no backend, no
dashboard, no device farm.

---

## The original problem

`waitForSettle` required three things at once: no request in flight, no
animation running, and no frame rendered for 500ms. A screen that
animates continuously never satisfies the second or the third, so the
wait never returned, and two of the external application's three screens
could not be photographed at all.

```
/home    the screen did not settle within 10s.
         Still waiting on: frames still rendering; 2 animations running
/orders  the screen did not settle within 10s.
         Still waiting on: frames still rendering; 1 animation running
```

A skip is honest, but it left visual regression covering one screen out
of three.

The fix is **not** `ignoreAnimations: true`. A flag whose cost is silent
visual flakiness is exactly the kind of convenience that gets a check
switched off. What follows is a **declared exception**: a screen names
the animations it expects, those stop blocking, and everything else
still does.

## What the evidence actually said

The count was the whole problem. "2 animations running" names nothing,
so the first work of this milestone was to make the application say
*which*. That immediately corrected the diagnosis.

The previous report guessed the dashboard ran "a banner carousel
continuously". It does not. Sampled on an SM-M127G:

| Screen | Animation | Where | Perpetual? |
|---|---|---|---|
| `/home` | `Navigator` | whole screen | no — the route transition in |
| `/home` | `CircularProgressIndicator` | `174,367 36x36` | no — the dashboard loading, 4.4s |
| `/home` | `Lottie` ×2 | `42,1587 33x33`, `42,1994 33x33` | **yes** — the discount badge on an outlet card |
| `/orders` | `Shimmer` | `0,146 384x599` | no — the orders list loading, 3.5s |

Two corrections follow from that table, and both matter more than the
feature:

1. **Three of the four are loading indicators.** They stop when the data
   arrives. The original 10-second wait was placed *before* the screen
   had arrived — cold start alone is 8.3s on this device — so it expired
   during loading, and a bare count could not tell that apart from a
   screen that never settles.
2. **A loading indicator must never be declared.** Excusing a spinner
   would make a screen that never finishes loading look settled. That is
   the defect class this feature exists to keep visible, so neither
   `/home` nor `/orders` declares its spinner or its shimmer.

The genuinely perpetual case is the pair of `Lottie` discount badges,
which loop for as long as the screen exists.

## How the inventory is built

Every widget-driven animation in Flutter runs on a `Ticker` created
through `TickerProviderStateMixin` or its single-ticker sibling, and both
mixins publish their tickers through `debugFillProperties`. Reading them
through `state.toDiagnosticsNode().getProperties()` is public API on both
sides — no protected-member access — and the property's `value` is the
real `Ticker`.

The predicate is **`Ticker.isTicking`**, not `isActive`. A ticker that is
started but muted — the state Flutter puts a covered route into — is
active, not ticking, and schedules no frame.

**The count is trustworthy.** Measured: the number of ticking tickers
equals `transientCallbackCount` exactly. That equality is what makes a
declared exception safe, because it means there is no unattributed
remainder for an undeclared animation to hide in. It is also asserted, in
`animation_inventory_test.dart`, and any shortfall is carried to the
engine as a blocker of its own:

```
1 animation running that the application could not name. Nothing can be
declared for it, so it still blocks.
```

Each entry carries the owning widget type, every semantic id enclosing
it, its route, and its bounds. It carries **no content** — an inventory
taken on a login screen must not become a second way to read a password.

## Syntax

```yaml
screen: /home

quiescence:
  allow:
    - element: home.body
      widget: Lottie
      reason: the discount badge on an outlet card loops continuously
```

| Key | | Meaning |
|---|---|---|
| `element` | required | the semantic id enclosing the animation |
| `widget` | optional | only animations owned by this widget type |
| `count` | optional | exactly how many are expected. Added in STOP-3, and only meaningful against a fixture |
| `reason` | required | why it runs for ever, in the author's words |

`reason` is required by design. The report says which pixels were
excluded from comparison and why, and a declaration that is tedious to
write is one nobody adds casually.

`widget` is the answer to a list. A dashboard draws a looping badge on
every outlet card that has an offer, so no id names one of them — putting
the same id on each would make it ambiguous for every other check.
Naming the *kind* keeps the exception specific instead: `Lottie` inside
`home.body` is permitted, and a shimmer appearing there tomorrow still
blocks.

Every one of these is a **parse error**, not a runtime surprise:

| Written | Result |
|---|---|
| `quiescence: true` | must be a mapping |
| `ignoreAnimations: true` | unknown quiescence key |
| `allow: home.body` | `"allow"` must be a list |
| an entry with no `element` | `"element"` is required |
| an entry with no `reason`, or a blank one | `"reason"` is required |
| `element: "*"` | must name one element, not a pattern |
| the same element and widget twice | declared twice |

## Resolution algorithm

Given the inventory, the policy, and the rest of the settle reading:

1. **Discard what is behind.** An animation whose route index differs
   from the topmost route belongs to a screen underneath. An animation
   whose route is *unknown* is not excused — not knowing where something
   is is not a reason to ignore it.
2. **Match.** An animation is permitted when some declaration names one
   of its enclosing ids and, if it names a widget type, that type.
3. **Anything unmatched is unexpected**, and blocks.
4. **A request in flight still blocks**, always. Permitting an animation
   says nothing about loading.
5. **The quiet period still applies — unless something was permitted.**
   A permitted animation renders a frame every 16ms, so waiting for quiet
   is waiting for ever. The frames are expected *because they were
   declared*, and their pixels leave the comparison for the same reason.

```
no animations                        → settled
only permitted animations            → settled
an unexpected animation              → not settled, named
an animation Flutter counted but
  the app could not name             → not settled
an invalid declaration               → ERROR, at parse time
```

No AI. No timing heuristic beyond the 500ms quiet period the
architecture already had, and that one is now applied in *fewer* places
than before, not more.

## Interaction with visual comparison

This is the part that could go quietly wrong, so it is worth stating
precisely.

```
declared animation
   → its own bounds become an ignore region
   → two photographs must agree outside the ignored regions
   → only then is the baseline compared
```

**The animation's own box, not the declared element's.** The two badges
are 33×33 each, inside a scroll body that fills the screen. Excluding
what was *declared* would have blanked the whole screen to hide 0.2% of
it. Excluding what actually **moves** costs almost nothing. The
declaration says what is permitted; the inventory says what to exclude.

**Two photographs, not one taken on trust.** A settle reading is taken
before the shutter, and the screen can change after it. Measured:
`awaitQuiescence` reported a quiet screen and the picture still caught
the outlet images part-way through their fade-in — **44% different** from
a baseline of the same screen fully painted, in 7 runs out of 8. Nothing
was wrong with either the reading or the capture; the gap between them is
simply real, and a quiet period cannot close it, because more than 500ms
can pass between one network image arriving and the next.

So the screen is photographed twice and the pair must agree outside the
ignored regions, up to three attempts. A permitted animation is already
excluded and so does not prevent agreement; a screen still assembling
itself does.

| | Before | After |
|---|---|---|
| `/home` exact match | **1 of 8** | **5 of 5** |

If it never holds still, the result is **SKIP** — an unstable screen is
something the tool could not measure, not a claim about the application.
The same applies when a permitted animation reports no bounds: its
changing pixels cannot be excluded, so comparing anyway would pass or
fail at random.

An undeclared animation makes the visual check an **ERROR**, never a
pass and never a fail:

```
! visual: cannot photograph "/home" deterministically: 2 unexpected
  animations running: Lottie at 42,1587 33x33 (no semantic id), Lottie at
  42,1994 33x33 (no semantic id). An animation with no semantic id cannot
  be declared - wrap it in a TestId first. If it is meant to run for
  ever, declare it under "quiescence: allow:" for this screen.
```

## Route isolation

Flutter does most of this itself, and the policy leans on it knowingly:

| Case | Ticking? | Why |
|---|---|---|
| an **opaque** route on top | no | `_OverlayEntryWidget` wraps each route in `TickerMode(enabled: tickerEnabled)` |
| an inactive `StatefulShellRoute` branch | no | go_router wraps each branch in `TickerMode(enabled: isActive)` |
| a **transparent** route on top — a dialog, a bottom sheet | **yes** | nothing mutes it |

The third row is why the policy filters by route index anyway. A dialog
over an animating dashboard leaves the dashboard ticking, and those
tickers must not count toward the dialog's quiescence. All three are
regression tests; the first two assert Flutter's behaviour rather than
assume it, because the design depends on it.

A declaration does not reach under the top route either: permitting is
scoped to the screen being validated, not to whatever is behind it.

## Reporting

Never silent. Whenever anything is moving, before the rows it affects:

```
quiescence:
  2 animations ticking
  2 permitted
  0 unexpected
    permitted: Lottie in "home.body" at 42,1587 33x33 - the discount badge on an outlet card loops continuously
    permitted: Lottie in "home.body" at 42,1994 33x33 - the discount badge on an outlet card loops continuously
```

A declaration that matched nothing is reported too — dead configuration
is worth saying out loud — but is not fatal, because erroring would make
the run depend on how much data a fixture happens to hold.

## Tests

**57** in `packages/flutter_testsmith_engine/test/quiescence_test.dart` and **18** in
`packages/flutter_testsmith/test/animation_inventory_test.dart`, written before
the implementation and failing against it. The SDK's run against **real
widgets** — the mechanism is Flutter's own bookkeeping, and a hand-built
tree would prove nothing about it.

| # | Case | Result |
|---|---|---|
| 1 | Zero animations | settled |
| 2 | One finite animation | blocks, then settles when it stops |
| 3 | Perpetual, undeclared | not settled, names the widget and says how to declare it |
| 4 | Perpetual, declared | settled; quiet period no longer applies |
| 5 | Declared plus unexpected | not settled; names **only** the unexpected one |
| 6 | Invalid declaration | ERROR at parse time, seven ways |
| 7 | Several declared | all settle; unused declarations reported |
| 8 | Animation under the current route | ignored, and reported as ignored |
| 9 | Visual with a permitted animation | its own bounds excluded, not the declared element's |
| 10 | No quiescence configuration | byte-for-byte the old behaviour |

Plus: `widget:` narrowing (permits the named kind, still blocks others,
two kinds on one element); the count matching `transientCallbackCount`; a
raw `Ticker` as well as an `AnimationController`; a muted subtree; an
older SDK that sends no inventory; and that the inventory carries no text
from the screen.

## Device evidence

Samsung SM-M127G, ExternalApp, live UAT backend.

**`/home`, with two permitted perpetual animations:**

```
quiescence:
  2 animations ticking
  2 permitted
  0 unexpected
    permitted: Lottie in "home.body" at 42,1587 33x33 - the discount badge on an outlet card loops continuously
    permitted: Lottie in "home.body" at 42,1994 33x33 - the discount badge on an outlet card loops continuously
✓ visual: "/home" matches the baseline: 0.000% of 1076400 pixels differ, ssim 1.0000
```

| Screen | Runs | Exact matches | Settle time |
|---|---|---|---|
| `/home` | 5 | **5** — 0.000%, ssim 1.0000 | 4.4s after arrival |
| `/orders` | 3 | **3** — 0.000%, ssim 1.0000 | 3.5s after arrival |
| `/profile` | 1 | **1** — unchanged, 5 ok 0 failed | — |

**Unexpected animations remain detectable**, demonstrated on device with
three different widgets: the two `Lottie` badges before the declaration
existed, the `CircularProgressIndicator` on `/home`, and the `Shimmer` on
`/orders`. Each was named, positioned, and blocked the photograph.

**`/profile` is untouched**: it declares no quiescence, and still passes
every check including STOP-1 provenance and the effective-text
resolution.

**Integration cost in the external application: one `TestId`**, wrapping
the dashboard's scrolling content so the badges inside it can be named.
No application logic changed.

## Limitations

- **The quiet period cannot apply while a permitted animation runs.**
  Frames render constantly by declaration, so a `setState` loop elsewhere
  on the same screen would no longer be caught by the frame check. The
  two-photograph rule covers the visual consequence; nothing covers a
  structural one.
- ~~**A declaration is only as tight as the id it names.**~~ **Closed by
  STOP-3.** `home.body` was the dashboard's whole scroll view, so a
  second `Lottie` added anywhere inside it would have been permitted
  without anyone noticing. Each outlet rail now carries its own id, and
  a `count:` key pins how many instances are expected — so a third
  Lottie on the declared rail blocks. See
  [STOP_3_DETERMINISTIC_E2E.md](STOP_3_DETERMINISTIC_E2E.md).
- ~~**`widget:` narrowing is proven by unit test, not on hardware.**~~
  **Closed by STOP-3.** The badges ticked only intermittently because
  they were built from live data; against the committed
  `dashboard_populated` fixture they tick on every run, and both a wrong
  `widget:` and a wrong `count:` were demonstrated failing on the
  SM-M127G and then restored.
- **An animation outside its own render box is not fully excluded.** A
  shadow or an overflow that a `Lottie` paints beyond its bounds stays in
  the comparison. Not observed; the whole-screen tolerance is the
  backstop.
- ~~**The `/home` and `/orders` baselines were recorded against the live
  UAT backend.**~~ **Closed by STOP-3.** Both are now recorded against
  committed fixtures — `dashboard_populated` and `orders_populated` —
  and match exactly in 5 runs out of 5 each, with no backend reachable.
  The live-data baselines were retired rather than kept.
- **A screen can be quiet and still unfinished.** This predates STOP-2
  and is unchanged by it: network images arriving more than 500ms apart
  leave quiet windows between them. The two-photograph rule makes the
  *visual* consequence go away; a tree captured in one of those windows
  is still a tree of a half-loaded screen.
