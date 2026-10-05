# E-06 — Deterministic UI validation against API and Figma: design

**Status:** approved for planning
**Date:** 2026-09-15

The user writes the test case. The deterministic system executes it,
obtains the API response and the Figma design, inspects the rendered
Flutter UI, compares each against the UI independently, and reports four
verdicts that cannot hide one another.

No AI is implemented in this milestone. No E-05 authentication
automation is implemented in this milestone.

---

## 1. What already exists, and what E-06 actually adds

E-06 reads as a large milestone. Measured against the repository it is
not, because three of its four demands were built in earlier phases and
work against a real application and a real design.

| E-06 asks for | State |
|---|---|
| UI↔API comparison with transformations | `ApiToUiValidator` — exists |
| UI↔Figma comparison: geometry, colour, typography, radius, spacing, hierarchy, order, padding, opacity | `FigmaStructureValidator`, 16 validator ids — exists |
| UI execution validation | flow steps + `UiPresenceValidator` — exists |
| PASS / FAIL / ERROR / SKIP, distinct | `ValidationStatus` — exists, with `blocksPass` |
| Explicit, human-owned mappings; no silent guessing | `mappings/<screen>.yaml` — exists |
| Configured tolerances that AI cannot move | `FigmaTolerances`, `VisualTolerances` — exists |
| Credential redaction | `SecretRef`/`Secret`, capture-time redaction — exists |
| API response from a **declared dev URL + method + endpoint + token** | **missing** |
| Figma design from a **Dev URL + token declared on the test** | **partial** — a separate `testsmith figma pull` writes JSON to disk |
| Separate **API / FIGMA / UI / OVERALL** verdicts | **missing** — `RunResult.passed` is one flat boolean |

Three gaps. The third is the heart of §5–§7 of the milestone and is
where the design spends most of its care, because it is the one that
changes how every existing result is read.

---

## 2. The principle this milestone adds

E-04 added one distinction and built everything on it: *a result says
something about the application, or it says something about the run.*

E-06 adds the second:

> **A verdict names the source of truth it was measured against.**
> "The screen is correct" is not a sentence this platform can say. It
> can say the UI matches the API, and the UI matches the design, and
> the steps executed — and it must say all three separately, because a
> reader who is told only "PASS" cannot tell which of them was checked.

The consequence that does the work: **a dimension nobody checked reports
SKIP, never PASS.** A PASS is a positive claim, and a claim requires
something to have been compared.

---

## 3. Verdict dimensions

### 3.1 Which dimensions exist

Four: `ui`, `api`, `figma`, `visual`.

The milestone names three. `visual` is included because it is already a
distinct dimension of this platform, not because E-06 asked for one —
the evidence, all of it pre-existing:

| Evidence | Where |
|---|---|
| A fifth tri-state flag on the step, beside api/ui/rules/figma | `ValidateScreenStep.visual` |
| Its own validator, explicitly **not** a `ScreenValidator` | `VisualValidator`, `id = 'visual'` |
| Its own top-level config block with its own tolerances, capture mode and ignore regions | `visual:` in `mappings/<screen>.yaml` |
| Its own on-disk artefacts and store | `visual_baselines/`, `BaselineStore` |
| Its own enablement rule, different from the other four | `runsVisual({required bool hasBaseline})` |

Folding `visual` into `figma` would merge a screenshot-versus-baseline
regression check with a design-conformance check. They fail for
different reasons and are fixed by different people. Dropping it from
the rollup would leave a dimension that already affects the pass/fail
outcome absent from the block that claims to explain it — which is the
hiding this milestone exists to prevent.

### 3.2 How a result is classified

Classification is **declared by the validator that produced the
result**, never inferred at report time from the validator's name. The
producing code is the only code that knows what it actually compared.

The rule it applies, in one sentence:

> **A result belongs to the dimension of the source of truth it was
> comparing the UI against — except when the comparison never happened
> because UI evidence was missing or ambiguous, which belongs to `ui`.**

Applied to every result site that exists today:

| Result | Dimension | Why |
|---|---|---|
| `ui-presence`, all results | ui | The UI is both subject and source |
| flow step outcomes (launch, tap, expectScreen, expectElement) | ui | Execution of the user-written steps |
| `api-to-ui` value match / mismatch | api | Compared against the API response |
| `api-to-ui` "mapped element is not on the screen" | api | The mapping's claim — *this API field appears here* — is what broke |
| `api-to-ui` "no UI tree was captured" | **ui** | The tool could not read the UI; nothing was compared |
| `api-to-ui` `PropertyAmbiguous` (one test id on two elements) | **ui** | A UI identity defect, not an API one |
| `api-to-ui` no response / unresolvable response | api | API evidence is missing |
| `expectApi` step outcomes | api | Asserted about the API |
| `rules` — condition read from the response, expectation checked on UI | api | See §3.3 |
| `rules` — "rules need a UI tree, and none was captured" | **ui** | UI evidence missing |
| `rules` — `PropertyAmbiguous` | **ui** | UI identity defect |
| `rules` — "rules need an API response" | api | API evidence missing |
| all 16 `figma-*` ids | figma | Compared against the design |
| `figma-identity` (one test id on two elements) | **ui** | UI identity defect; the design is not in question |
| `visual` | visual | Compared against an accepted baseline |

### 3.3 Why `rules` is an API dimension, established rather than assumed

`RulesValidator` calls `condition.evaluate(response.readPath)`. The
reader passed in is the **API response**, always — `Condition` has no
access to the UI snapshot and no code path that gives it one. A rule is
therefore, structurally:

```
API response satisfies <condition>   ⇒   UI must show <expectation>
```

which is an API→UI consistency statement in conditional form, and
belongs in `api`. This is read off the implementation, not off the
validator's name: were a future condition able to read a UI property,
the classification of that result would have to change with it, and
because the validator declares its own dimensions that change would be
made in one place.

The two exceptions in the table above are the cases where the rule never
got as far as comparing anything, because the UI could not be read.

### 3.4 Aggregation

Within a dimension, and then across dimensions, E-03's precedence
applies unchanged:

```
ERROR  >  FAIL  >  PASS  >  SKIP
```

Stated as the rule the code implements:

```
if any result ERROR  -> ERROR
else if any FAIL     -> FAIL
else if any PASS     -> PASS
else                 -> SKIP        (every result skipped, or there were none)
```

`SKIP` last is the load-bearing line. A dimension that was configured
but never ran, or was never configured at all, reports SKIP. It does not
report PASS, and it never becomes PASS by virtue of the other three
passing.

`ERROR` outranking `FAIL` preserves E-04: a run that could not answer the
question must not be readable as a run that answered it.

### 3.5 Where the rollup lives, and why it cannot drift

`RunResult` gains a **computed** `dimensions` getter — a pure function of
the `steps`, `screens` and `apiChecks` it already holds. No new stored
state, no second place where a verdict is decided.

This is the property the whole section rests on: **the dimension block
cannot disagree with the flat result, because it is derived from it.**

Guarded by a property test:

```
RunResult.passed   ⟺   overall ∈ { PASS, SKIP }
```

stated that way rather than as `overall == PASS`, because a run in which
nothing was checked at all has `passed == true` vacuously and rolls up to
SKIP. That is consistent with the rest of the platform — `SuiteVerdict.skip`
already exits 0 — and it mirrors `ValidationResult.blocksPass` exactly:
`passed` is true precisely when the overall verdict does not block a pass.

Asserted for every combination of step, screen and API-check outcomes.
E-03 and E-04 verdicts, exit codes and aggregate semantics are therefore
provably unmoved by this milestone.

### 3.6 The reported shape

```
Test: product_details

UI:       PASS
API:      FAIL
FIGMA:    PASS
VISUAL:   SKIP    no baseline recorded for "/product/details" yet

OVERALL:  FAIL

API failure
  product.price does not match response.price
    API returned        120
    currency(INR) gives Rs 120
    the UI shows        Rs 100
    source              GET /products/123, captured on /product/details
    mapping             response.price -> product.price.text
```

---

## 4. API acquisition

### 4.1 Captured traffic is preferred; a fetch is a fallback

The platform's existing position is that api-to-ui compares against what
the **application received**, through the SDK's capture — because
asserting against the server's own reply proves only that the server
works, and because a response served from the app's own cache appears in
one and not the other.

E-06 §2 asks for a response obtained from a declared dev URL. Both are
kept, and the order is fixed:

> **Captured traffic is always preferred when the required response is
> available. `apiSource:` is consulted only when it is not.**

So a fully-instrumented run issues **zero outbound API requests**. The
fetch is lazy: no HTTP call is made unless the captured lookup came back
empty. A run therefore has no side effects on the backend it is testing
unless the capture failed to provide what the screen declared it needed.

### 4.2 Which captured response is "required" — deterministic matching

"Preferred when available" is only meaningful if *which* response is
required is defined without guessing. It is decided by the first of
these the mappings file declares:

| # | Declaration | Matching |
|---|---|---|
| 1 | `usesResponseFrom:` | The existing `ResponseResolver`, whole-session, with `occurrence`, `capturedOn` and `maxAge`. `only` refuses ambiguity. |
| 2 | `api: METHOD /path` | Completed exchanges **on this screen**, in capture order, first match by `ApiEndpoint.matches` (a `*` segment is a wildcard). |
| 3 | `apiSource:` | A derived `ApiEndpoint(method, Uri.parse(baseUrl).path + endpoint)`, matched against completed exchanges on this screen with **`only` semantics** — more than one match is ambiguity, not a race to be won by ordering. |
| 4 | nothing declared | The first completed exchange on this screen, whatever it is. |

Rows 2 and 4 are **existing committed behaviour and are not changed**.
Row 2 takes the first match silently where row 1 would refuse. That
inconsistency is pre-existing; tightening it would turn currently-passing
runs into errors, which §18 forbids. It is recorded in §11 as a known
limitation with the recommendation — declare `usesResponseFrom:` — that
removes it.

Row 3 is new, so it is given the stricter semantics from the outset.

Deriving row 3's path from `baseUrl` rather than from `endpoint` alone
is deliberate: `baseUrl: https://host/api/v1` with `endpoint:
/products/123` yields `/api/v1/products/123`, which is the path the
application's own request carries. Matching on `/products/123` would
miss it.

### 4.3 The fallback decision

```
captured lookup = Resolved     -> use captured        provenance: captured
captured lookup = Ambiguous    -> api = ERROR         no fetch is issued
captured lookup = Unavailable:
      apiSource declared       -> fetch
            2xx + JSON         -> use fetched         provenance: fetched
            anything else      -> api = ERROR, with an actionable reason
      apiSource absent         -> api = ERROR         (existing message, unchanged)
```

**Ambiguity never falls back.** Two captured responses matched and the
declaration does not say which; issuing a third request and preferring it
would silently answer a question the platform elsewhere refuses to
answer, and would let the runner's own fetch override two real responses
the application actually received.

### 4.4 Provenance is recorded, always

Every `api-to-ui` result carries which source it rests on, as structured
evidence beside the existing chain:

```
responseProvenance   captured | fetched
fallbackReason       <why capture did not supply it>   (fetched only)
fetchedFrom          GET /products/123                 (fetched only, path only)
```

A reader must never have to guess whether a PASS was measured against
the application's own traffic or against a request the runner made. This
is the same commitment STOP-1 made for screen attribution.

### 4.5 Declaration

```yaml
# mappings/product_details.yaml
apiSource:
  baseUrl: env:EXAMPLE_API_BASE
  method: GET
  endpoint: /products/123
  token: env:EXAMPLE_API_TOKEN     # a reference, never a literal
  headers:                        # optional
    Accept: application/json
  query:                          # optional
    include: pricing
  body: |                         # optional, non-GET only
    {"id": 123}
```

Unknown keys are refused with the nearest valid key, as every other
block in this file already is.

### 4.6 The fetch, and what it must not do

`ApiFetcher` is an interface, mirroring the existing `FigmaHttp`, so
every test in this milestone runs with no network. The `dart:io`
implementation lives in `flutter_testsmith_cli`, keeping `flutter_testsmith_engine` free of
transport concerns as it already is.

The response is normalised into the **existing** `ApiResponsePayload`.
`ApiToUiValidator` and `RulesValidator` are therefore not modified at
all — they already consume that type.

Security, enforced by construction rather than by care:

- `token:` is parsed into a `SecretRef`. A literal is **refused at parse
  time**, with the same message `SecretRef.parse` already gives.
- The value is resolved once, immediately before the request, placed
  directly into the header, and not retained.
- Request headers never enter `ApiResponsePayload`, never enter
  `Evidence`, and never reach `result.json` or `report.html`.
- `baseUrl` may itself be an `env:` reference. It is not treated as a
  secret — it is a URL — but it is resolved through the same mechanism
  so a missing one fails with the same actionable message.
- Every error message names the endpoint and the status, never the
  headers.

---

## 5. Figma acquisition

### 5.1 Declared on the test, resolved through the existing client

```yaml
# mappings/product_details.yaml
figmaSource:
  url: https://figma.com/design/<key>/File?node-id=909-1
  token: env:FIGMA_TOKEN
  mapping: figma/product_details.mapping.yaml
```

Resolved once per screen at run start through the **existing**
`FigmaClient`, its on-disk cache at `<project>/figma/.cache`, and the
existing `FigmaNormaliser`, producing the same `FigmaScreenSpec` the
on-disk path produces today. There is no second Figma integration, and
`FigmaTarget.parseUrl` already handles the `node-id=909-1` →
`909:1` translation.

Cache-backed rather than always-refetch: Figma rate-limits, a design does
not change between two steps of one run, and a milestone named for
determinism should not make two runs of the same test able to see
different designs.

### 5.2 Precedence and reporting

An explicit `figmaSource:` wins over an on-disk `figma/<screen>.json`
for that screen. Which was used is stated in the report, because a stale
on-disk spec silently shadowing a declared URL would be exactly the kind
of quiet wrongness the platform exists to avoid.

### 5.3 The node-to-semantic-id mapping stays mandatory

Unchanged from ADR §10.7, and not negotiable in this milestone: real
frames name their layers `Frame 42980`, `Rectangle 91`, `Component 3`.
Inferring semantic ids from layer names produces something that looks
like it works and is wrong. `testsmith figma pull
--write-mapping-template` remains the way to start one.

A `figmaSource:` with no resolvable mapping file yields **figma =
ERROR**, naming the file — not a skip, because a design *was* declared
and the run could not honour the declaration.

### 5.4 Failure

Invalid token, unreachable file, missing node, rate limit: **figma =
ERROR**, carrying `FigmaClient`'s existing typed message, which already
names the file key and the status and already never echoes the token.

---

## 6. Secret handling as a neutral primitive

`SecretRef`, `Secret`, `SecretResolver`, `MissingSecretException` and
`redactionMarker` currently live in
`packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart`, which is untracked
E-05 work. E-06 must not depend on uncommitted authentication code.

**They move**, and E-06 owns them:

```
packages/flutter_testsmith_engine/lib/src/auth/secret_ref.dart
  ->  packages/flutter_testsmith_engine/lib/src/secrets/secret_ref.dart

packages/flutter_testsmith_cli/lib/src/env_secret_resolver.dart
  ->  packages/flutter_testsmith_cli/lib/src/secrets/env_secret_resolver.dart
```

Six import sites are updated (`auth_flow.dart`, `auth_result.dart`,
`adb_device_controller.dart`, `device_controller.dart`, `dsl/steps.dart`,
and the `flutter_testsmith_engine` barrel), plus the CLI's own resolver consumers.
Three of those files are tracked and already modified by E-05, so this
is an import-line change in code that exists, not an implementation of
anything.

The dependency direction after the move is **`auth/` → `secrets/`, never
the reverse**. Nothing in `secrets/` knows that authentication exists.
If the E-05 working-tree changes are reverted, `secrets/` stands, and
E-06 still compiles and still handles the API and Figma tokens.

Reusing a secret-handling primitive is not authentication automation.
None of §19's prohibited E-05 items — no auth flow, no credential entry,
no login driving, no `testsmith auth` work — is implemented or extended
here.

---

## 7. No DSL change

§1 of the milestone says reuse the existing flow DSL and do not create a
second test language. The design does not add a step, an argument, or a
top-level key to `test_flow.dart`.

### 7.1 Where a user declares things, and who owns it

A user-written test case is **two user-owned files**, and the split is by
lifetime, not by convenience:

| File | Owns | Lifetime |
|---|---|---|
| `tests/<flow>.yaml` | What this test *does* — the steps, in order | One test |
| `mappings/<screen>.yaml` | What this *screen* is — its API source, its design source, its field mappings, its rules, its tolerances | Every test that visits the screen |

**`mappings/<screen>.yaml` is user-owned test configuration.** It is
hand-written, git-tracked, and the engine never rewrites it — AI
proposals land under `suggested:` and stay inert until a person moves
them up. E-06 adds two blocks to it, `apiSource:` and `figmaSource:`, and
changes nothing about that ownership.

Acquisition belongs there rather than on the flow because it is
**screen-scoped**: a URL declared once is inherited by every flow that
visits the screen. Declared on the flow instead it would be duplicated
across the five flows that touch a screen, and two of them would
eventually disagree — at which point the platform would be comparing the
same screen against two different sources of truth and reporting both as
authoritative.

`mappings/<screen>.yaml` is already where `api:`, `figma:`, `visual:`,
`rules:` and `usesResponseFrom:` live.
A URL declared there is written once and inherited by every flow that
visits the screen; declared on the flow instead it would be duplicated
across the five flows that touch it, and two of them would eventually
disagree.

`validateScreen` already runs every dimension and already skips with a
reason what is not configured. The user-written test case is unchanged:

```yaml
appId: com.example.ecommerce_app
flow: product_details

steps:
  - launchApp
  - waitForSettle
  - tap: { id: home.open_product }
  - expectScreen: { id: /product/details }
  - waitForSettle
  - validateScreen          # api, ui, rules, figma, visual
```

---

## 8. Result model and reporting

- `RunResult.toJson()` gains a `dimensions` object: per-dimension
  verdict, counts, and the reason for a non-PASS.
- `RunResult.schemaVersion` 1.0 → **1.1**. Purely additive: every
  existing key keeps its meaning, so existing consumers are unaffected.
- `HtmlReporter` renders the dimension block first, above the per-screen
  detail. It remains a pure function of the JSON.
- `SuiteTestResult` carries the dimensions of its run, so a suite report
  can show which dimension failed per test without re-deriving it.
- Terminal output prints the four-row block at the end of a run.

`ValidationResult` gains an optional `dimension` field. Each validator
stamps its own default over the results it returns; the field is passed
explicitly only where a result's dimension differs from that default.
Counted against the current code, that is **six sites**:

| Site | Override |
|---|---|
| `validators.dart:326` — api-to-ui, no UI tree captured | ui |
| `validators.dart:422` — api-to-ui, `PropertyAmbiguous` | ui |
| `validators.dart:599` — rules, the "needs a UI tree" arm of the ternary (the "needs an API response" arm stays api) | ui, conditionally |
| `validators.dart:657` — rules, `PropertyAmbiguous` | ui |
| `figma_structure_validator.dart:94` — no UI tree captured | ui |
| `figma_structure_validator.dart` — the `figma-identity` result | ui |

`ui-presence` needs no override: its default is already `ui`.

Six overrides plus one default per validator, rather than the 117
construction sites a required parameter would touch — and, unlike a
report-time lookup table, with no matching on validator names or message
text anywhere. A test asserts that every result reaching a report carries
a dimension.

---

## 9. Tests

Covering §17's twenty-three items. No existing test is deleted or
weakened.

**Dimension verdicts** — per-dimension aggregation for all four
statuses; precedence within and across dimensions; SKIP when nothing
ran; SKIP never promoted to PASS; the `overall == pass ⟺
RunResult.passed` property test; `rules` classified from its inputs; the
UI-evidence exceptions of §3.2; every result carries a dimension.

**API acquisition** — `apiSource:` parses; unknown keys refused; a
literal token refused at parse time; captured preferred when resolvable;
fetch issued only on Unavailable; **no fetch issued on Ambiguous**;
derived endpoint matching including the `baseUrl` path prefix; `only`
semantics on row 3; fetch 200/JSON, 401, timeout, connection refused,
non-JSON, non-2xx each producing api = ERROR with an actionable reason;
provenance recorded for both sources.

**Figma acquisition** — `figmaSource:` parses; URL with `node-id=a-b`
resolves; `figmaSource` beats on-disk spec; missing mapping file →
ERROR; invalid token → ERROR; unknown node → ERROR; cache hit issues no
request.

**Comparison** — API→UI match and mismatch with the full expected /
transformed / actual chain; Figma→UI match and mismatch; unknown API
mapping; unknown Figma node; unknown UI test id; tolerance respected
exactly and not adjusted.

**Combinations** — API PASS + Figma PASS + UI PASS → overall PASS; API
FAIL + Figma PASS + UI PASS → overall FAIL; API PASS + Figma FAIL + UI
PASS → overall FAIL; UI execution failure; API ERROR; Figma ERROR.

**Security** — API token absent from `result.json`, `report.html`,
terminal output, step descriptions and every error message; Figma token
likewise; a deliberately-leaky error path proves the assertion can fail.
Extends the existing `report_leakage_test` and `token_redaction_test`
rather than replacing them.

**Regression** — the full existing suite, `dart analyze --fatal-infos`,
the E-04 suite, and the generated evidence matrices regenerated and
diffed: `docs/evidence/api_to_ui_matrix.md`,
`figma_flutter_defect_matrix.md`, `figma_defect_matrix.md`,
`api_transport_matrix.md`, `ui_state_matrix.md`. A row that changes must
be explained or reverted; none is expected to.

---

## 10. Acceptance

The milestone lists thirty-eight criteria. **Thirty-three are addressed
by the design above.**

*Addressed* is not *met*. A criterion is marked MET only once the code
exists, the test that shows it passes, and the command that produced the
evidence is recorded. Until then this section states intent, not
achievement — which is the same distinction the platform makes between a
dimension that was checked and one that merely had nothing to say.

**Five are not addressed at all, and will be reported as NOT MET**,
because no device and no credentials are available:

- ExternalApp demonstrates a real complete flow
- ExternalApp demonstrates API PASS
- ExternalApp demonstrates Figma PASS
- ExternalApp demonstrates UI PASS
- ExternalApp demonstrates overall PASS

The thirty-fourth — *a deliberate API or Figma mismatch produces a
deterministic FAIL* — names no application, and is met against
`examples/ecommerce_app`.

The demonstration runs instead against `examples/ecommerce_app`, which
has a real Figma frame pulled from the real API (`909:1` of
`<redacted>`), real committed baselines, and a fixture
server — including the deliberate failure of §15. That is a genuine
end-to-end demonstration and it is **not** the ExternalApp demonstration
the milestone asks for. The two are reported separately and the
distinction is not blurred.

---

## 11. Known limitations, carried into the doc

1. **Row 2 of §4.2 takes the first match silently.** `api: GET /x` picks
   the earliest matching completed exchange where `usesResponseFrom:`
   would refuse two. Pre-existing; unchanged deliberately, because
   changing it would turn passing runs into errors. Declaring
   `usesResponseFrom:` removes the ambiguity.
2. **A fetched response is not the response the application saw.** When
   the fallback fires, the comparison is against a request the runner
   made, which a non-deterministic or stateful backend may answer
   differently. This is why capture is preferred and why provenance is
   always recorded — but a PASS resting on a fetch is a weaker claim
   than one resting on capture, and the report says which it is.
3. **The Figma cache can serve a stale design.** Deliberate, for
   reproducibility. `--refresh` on `testsmith figma pull` is the escape.
4. **The node-to-semantic-id mapping is still hand-written.** No part of
   this milestone infers it.
5. **`visual` remains opt-in on a first run**, because it writes a file
   into the repository. Unchanged from Phase 12.
6. **iOS is still out of reach** on this host.
