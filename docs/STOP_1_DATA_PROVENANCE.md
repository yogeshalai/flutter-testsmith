# STOP-1: data provenance

**Status:** implemented (this milestone).
**Scope:** STOP-1 only. Nothing else in the platform was changed.

---

## The problem

API-to-UI validation assumed that the response a screen displays was
captured **while that screen was current**. Real applications do not
work that way: data is fetched during a splash screen, on another tab,
or by a cache warmed minutes earlier, and the screen that renders it
makes no request at all.

When that assumption fails, the platform's central capability — compare
what the API returned against what the UI shows — cannot run.

## The evidence

From external-application validation against ExternalApp, a 745-file
Riverpod / go_router / dio application. Its `/profile` screen renders the
consumer's name. The request that fetched it happens during startup and
the result is held by a `keepAlive` provider.

```
ERROR api-to-ui — the mappings name "GET /api/profile/me",
which this screen did not call. It called:
GET /v4beta/geocode/location/18.5448976,73.7858687.
```

The only exchange attributed to `/profile` was a **third-party
geocoding call to another host**. Re-selecting the tab to force a
refresh did not change it. Across four screens of that application,
**no screen captured the response it rendered.**

## The previous architecture

```
ScreenSession   one screen, one entry time, one list of exchanges
      ↓
ValidationContext.response
      ↓
  the first completed exchange on that screen
  (or, since the external-app milestone, the one matching `api:`)
```

`ValidationContext` could see exactly one `ScreenSession`. A response
captured anywhere else was invisible to it — correctly, because there
was no way to say which one was meant.

## The new architecture

Provenance is modelled as a **declared reference from a screen to a
response**, resolved over the whole session. It is deliberately *not*
a model of repositories, caches or providers — that would be a much
larger change and is explicitly out of scope.

```
mappings file
      ↓  usesResponseFrom: (explicit declaration)
ResponseResolver
      ↓  searches every ScreenSession in the run
ResolvedResponse   payload + endpoint + screen + timestamp + requestId + age
      ↓
ApiToUiValidator / RulesValidator
      ↓
report: source endpoint, source screen, source timestamp, request id,
        raw value, transformed value, UI value
```

Three properties hold by construction:

1. **Nothing happens without a declaration.** A screen that says nothing
   about provenance is validated exactly as before, against its own
   exchanges. There is no automatic fallback and no "most recent
   matching response" search.
2. **`ValidationContext` no longer assumes one screen owns one API
   session.** It takes the session history; the single-session
   behaviour is what you get when no history is supplied.
3. **A resolution is a sealed result**, not a nullable payload:
   *resolved*, *unavailable*, or *ambiguous*. The three need different
   words in a report, and collapsing them is how a missing response
   comes to read as a wrong value.

## Syntax

```yaml
screen: /profile

usesResponseFrom:
  endpoint: GET /api/profile/me   # required
  occurrence: only                        # only (default) | first | last
  capturedOn: /home                       # optional
  maxAgeSeconds: 120                      # optional

mappings:
  - target: profile.display_name
    source: response.data.firstName
```

| Key | Meaning |
|---|---|
| `endpoint` | `METHOD /path`. A path segment may be `*`, so `GET /api/orders/*` survives a changing id. |
| `occurrence` | Which of several matches is meant. **`only` is the default and refuses to choose.** |
| `capturedOn` | Only consider responses captured while that screen was current. |
| `maxAgeSeconds` | How old the response may be when this screen was entered. |

Every one of these is validated when the file is **parsed**, not when a
run reaches the screen: a malformed `endpoint`, an unknown `occurrence`,
an unknown key or a negative `maxAgeSeconds` is a parse error. A
declaration that silently did nothing would leave a screen validating
against the wrong response, which is the failure this exists to remove.

`api:` is unchanged and still means "the endpoint this screen calls
itself". The two are independent.

## The resolution algorithm

Stated in full so it can be argued with:

1. Consider every **completed** exchange in every screen session of the
   run, in capture order.
2. Keep those whose method and path match `endpoint`.
3. If `capturedOn` is set, keep only those captured on that screen.
4. **Nothing left** → *unavailable* → **ERROR**, listing what the
   session did capture.
5. **More than one left** → `occurrence` decides:
   - `only` → *ambiguous* → **ERROR**, naming every candidate and the
     screen and time each was captured on;
   - `first` → the earliest;
   - `last` → the most recent.
6. If `maxAgeSeconds` is set and the chosen response is older than that
   relative to the rendering screen's entry → *unavailable* → **ERROR**,
   naming the age and the limit.
7. Otherwise → *resolved*.

**Recency is never consulted unless a person wrote `last`.** Step 5 is
the whole point: the platform does not break a tie, it reports one.

## Stale-response protection

Three mechanisms, in order of how much they ask of the author:

1. **`occurrence: only` is the default.** If the endpoint was called
   twice, that is an ambiguity and an ERROR. A screen cannot silently
   pick up a stale first response when a fresher one exists, nor the
   reverse.
2. **`maxAgeSeconds`** puts an explicit bound on how old the data may
   be. Over it is an **ERROR**, not a failure — the application may be
   perfectly correct, and what is wrong is that nothing recent enough
   was captured to judge it against.
3. **The age is always reported**, whether or not a limit is set, as
   `sourceAgeSeconds` and in the message. A reviewer can see that a
   passing comparison was made against data captured four minutes
   earlier.

A response captured *after* the screen was entered has an age of zero,
not a negative number.

## Ambiguity handling

```
ERROR api-to-ui — 2 responses match `usesResponseFrom: GET
/api/profile/me`, so which one this screen is showing is
ambiguous. They were captured on: / at 2026-09-12T10:00:05.000Z;
/home at 2026-09-12T10:00:12.000Z. Add `occurrence: first` or
`occurrence: last`, or `capturedOn:`, to say which one is meant.
```

The message names every candidate and the two ways to resolve it. It is
an **ERROR**, so it blocks a pass without being read as an application
defect.

## Examples

**A screen that fetches its own data** — unchanged, no declaration:

```yaml
screen: /product/details
api: GET /products/123
mappings:
  - target: product.price
    source: response.price
    transformation: currency(INR)
```

**A screen rendering data fetched at startup:**

```yaml
screen: /profile
usesResponseFrom:
  endpoint: GET /api/profile/me
mappings:
  - target: profile.display_name
    source: response.data.firstName
```

**An endpoint polled repeatedly, where the newest is meant:**

```yaml
usesResponseFrom:
  endpoint: GET /api/cart
  occurrence: last
  maxAgeSeconds: 30
```

**The same endpoint called on two screens, where one is meant:**

```yaml
usesResponseFrom:
  endpoint: GET /api/profile/me
  capturedOn: /home
```

## What the report shows

Every required field, in `result.json` and in the HTML:

```
sourceEndpoint   = GET /api/profile/me
sourceScreen     = /
sourceCapturedAt = 2026-09-12T13:32:44.454943Z
sourceRequestId  = 54f8e005-0c90-4846-9cc9-1be8cbb025f3
sourceAgeSeconds = 2
renderedScreen   = /profile
apiPath          = response.data.firstName
apiValue         = Test
transformation   = identity
transformedValue = Test
element          = profile.display_name
property         = text
uiValue          = Test
```

and in the terminal:

```
✓ api-to-ui profile.display_name: response.data.firstName matches
  profile.display_name.text (from GET /api/profile/me captured
  on "/", 2s earlier)
```

The provenance clause appears **only** when the source screen differs
from the rendered screen. A screen validating against its own response
reads exactly as it did before.

## Verdict semantics

Unchanged, and deliberately so.

| Situation | Verdict |
|---|---|
| Declared response found, values match | **PASS** |
| Declared response found, values differ | **FAIL** |
| Declared response never captured | **ERROR** |
| Several candidates, `occurrence: only` | **ERROR** |
| Chosen response older than `maxAgeSeconds` | **ERROR** |
| No mappings configured | **SKIP** |

Missing source data is never converted into a FAIL. AI takes no part in
any of it, and there is no code path by which it could.

## Limitations

- **Provenance is declared, not discovered.** The platform does not know
  that a provider cached a response; a person writes it down. That is
  the intended trade for auditability, and it means a screen whose
  declaration is wrong will report an honest error rather than a wrong
  pass.
- **No repository / provider tracing.** Explicitly out of scope for this
  milestone. The chain `API → repository → screen` is modelled only at
  its two ends.
- **One source per screen.** A screen rendering fields from two
  endpoints cannot yet declare both. The model would extend naturally to
  named sources (`source: profile.data.firstName`), and nothing here
  forecloses it.
- **`capturedOn` matches a screen id exactly.** No wildcards.
- **Ambiguity is resolved positionally**, by `first` / `last` over
  capture order. There is no way to say "the one whose body contains
  X".
- **Unattributed exchanges are not searched.** `CorrelationResult`
  keeps exchanges that belong to no screen; the resolver walks screen
  sessions only. A response captured before the first screen entry is
  therefore invisible. Not observed in practice — the startup requests
  of the external application were all attributed to `/` — but it is a
  real gap.

## An open observation, not part of this milestone

Enabling provenance let a rule run on the external application that had
never been able to run before, and it immediately surfaced something
else: `profile.complete_button.text` reads as `null` even though the
button has exactly one `Text` descendant. The element is present, and
`visible` reads correctly. The cause is not established. It is recorded
here because provenance is what exposed it, and it is **not** a STOP-1
defect.

> **Since resolved**, as its own milestone. The button has *two*
> text-bearing descendants: a `Text` and a Material `Icon`, which renders
> a private-use codepoint through a `RichText`. See
> [UI_PROPERTY_RESOLUTION.md](UI_PROPERTY_RESOLUTION.md). Nothing in the
> provenance architecture changed.

## Tests

26 tests in `packages/flutter_testsmith_engine/test/data_provenance_test.dart`,
written before the implementation and failing against it, covering every
scenario the milestone required:

| # | Scenario | Tests |
|---|---|---|
| 1 | API captured before screen entry | 2 |
| 2 | Multiple unrelated API responses | 1 |
| 3 | Same endpoint called multiple times | 4 |
| 4 | Same API used by multiple screens | 1 |
| 5 | Declared endpoint never captured | 2 |
| 6 | Multiple candidates with ambiguity | 2 |
| 7 | Response captured on another screen | 1 |
| 8 | Raw → transformed → UI comparison | 1 |
| 9 | Stale response protection | 4 |
| 10 | Existing same-screen behaviour unchanged | 3 |
| — | Declaration parsing and defaults | 5 |

Plus 3 in `reporting_test.dart` for the report fields, and the existing
suites re-run unchanged.

**On the device:** the ExternalApp `/profile` acceptance case, which
previously errored, now reports

```
/profile  PASS  4 ok, 0 failed, 1 skipped, 0 errored
```

with the source screen (`/`) different from the rendered screen
(`/profile`).
