# E-06 — Deterministic UI validation against API and Figma

A user-written test case, executed against a real Flutter application,
with the rendered UI compared independently against the API response and
against the Figma design — and five verdicts that cannot hide one
another.

No AI decides anything here. No authentication is automated here.

Read this if you are writing a test that validates a screen against its
API and its design, or if a report told you `FIGMA FAIL` and you want to
know what that claim rests on.

---

## 1. Architecture

```
            mappings/<screen>.yaml          tests/<flow>.yaml
            (what the screen IS)            (what the test DOES)
                     │                              │
                     └──────────────┬───────────────┘
                                    ▼
                        deterministic runner
                                    │
                                    ▼
                            Flutter UI  ── widget + semantics tree,
                                 │          bounds, text, testIds
                    ┌────────────┴────────────┐
                    ▼                         ▼
            API response                Figma design
        captured, else fetched      Dev URL + token, cached
                    │                         │
                    ▼                         ▼
             api-to-ui, rules          figma-* (16 checks)
                    │                         │
                    └────────────┬────────────┘
                                 ▼
                    UI · API · FIGMA · VISUAL
                                 ▼
                             OVERALL
```

Three things were added in this milestone. Everything else already
existed and was reused unchanged.

| Added | Where |
|---|---|
| A `ValidationDimension` stamped on every result **by the validator that produced it** | `validation/validation_dimension.dart`, `reporting/dimension_verdict.dart` |
| An API response fetched from a declared dev URL, **only** when the capture cannot supply it | `validation/api_source.dart`, `api_fetcher.dart`, `api_acquisition.dart` |
| A Figma design resolved from a URL declared on the test | `validation/figma_source.dart`, `flutter_testsmith_cli/figma_source_resolver.dart` |

**No DSL change.** No step, argument or top-level key was added to
`test_flow.dart`. `validateScreen` already ran every dimension.

---

## 2. The user-written test case

A test case is **two user-owned files**, split by lifetime:

| File | Owns | Lifetime |
|---|---|---|
| `tests/<flow>.yaml` | What this test *does* — the steps, in order | one test |
| `mappings/<screen>.yaml` | What this *screen is* — API source, design source, field mappings, rules, tolerances | every test that visits the screen |

**`mappings/<screen>.yaml` is user-owned test configuration.** It is
hand-written, git-tracked, and the engine never rewrites it. AI
proposals land under `suggested:` and stay inert until a person moves
them up. E-06 adds two blocks to it and changes nothing about that
ownership.

Acquisition lives there rather than on the flow because it is
**screen-scoped**: a URL declared once is inherited by every flow that
visits the screen. Declared on the flow it would be duplicated across
the five flows that touch a screen, and two of them would eventually
disagree — at which point the platform would compare one screen against
two different sources of truth and call both authoritative.

### 2.1 The flow

[`examples/ecommerce_app/tests/product_three_way.yaml`](../examples/ecommerce_app/tests/product_three_way.yaml):

```yaml
appId: com.example.ecommerce_app
flow: product_three_way

steps:
  - launchApp
  - waitForSettle
  - tap: { id: login.submit }
  - expectScreen: { id: /home }
  - waitForSettle
  - tap: { id: home.open_product }
  - expectScreen: { id: /product/details }
  - waitForSettle
  - validateScreen      # api, ui, rules, figma, visual — each reported separately
```

### 2.2 The screen

[`examples/ecommerce_app/mappings/product_details.yaml`](../examples/ecommerce_app/mappings/product_details.yaml), abridged:

```yaml
screen: /product/details
api: GET /products/123

apiSource:                          # fallback only — see §3
  baseUrl: env:EXAMPLE_MOCK_BASE
  method: GET
  endpoint: /products/123
  # token: env:EXAMPLE_API_TOKEN      # a reference; a literal is refused

figmaSource:                        # see §4
  url: https://www.figma.com/design/<redacted>/App?node-id=913-1
  token: env:FIGMA_TOKEN
  mapping: figma/product_details.mapping.yaml

mappings:
  - target: product.name
    source: response.name
  - target: product.price
    source: response.price
    transformation: currency(INR)
  - target: product.add_to_cart
    property: enabled
    source: response.available

figma:
  positionPx: 2                     # tighter than the platform default,
  sizePx: 2                         # deliberately

rules:
  - condition: "available == false"
    expectations:
      - element: product.add_to_cart
        property: enabled
        equals: false
```

---

## 3. API acquisition

### 3.1 Captured traffic is preferred; a fetch is a fallback

> **Captured traffic is always preferred when the required response is
> available. `apiSource:` is consulted only when it is not.**

A fully-instrumented run therefore issues **zero outbound API requests**.
The fetch is lazy: no HTTP call is made unless the captured lookup came
back empty, so a run has no side effects on the backend it is testing.

Why capture is preferred: asserting against the server's own reply
proves only that the server works. A response served from the
application's own cache appears in one and not the other, and that
difference is the whole reason the capture exists.

### 3.2 Which captured response is "required"

Decided by the first of these the mappings file declares. No guessing.

| # | Declaration | Matching |
|---|---|---|
| 1 | `usesResponseFrom:` | The existing `ResponseResolver`, whole-session, honouring `occurrence`, `capturedOn`, `maxAge`. `only` refuses ambiguity. |
| 2 | `api: METHOD /path` | Completed exchanges **on this screen**, first match by `ApiEndpoint.matches` (a `*` segment is a wildcard). |
| 3 | `apiSource:` | A derived `ApiEndpoint(method, baseUrlPath + endpoint)`, matched with **`only` semantics**. |
| 4 | nothing | The first completed exchange on this screen. |

Row 3 derives its path from the **base URL's path plus the endpoint**: a
base of `https://host/api/v1` with endpoint `/products/123` is the request
the application makes as `/api/v1/products/123`. Matching on the endpoint
alone would miss it.

Rows 2 and 4 are pre-existing committed behaviour and are unchanged.

### 3.3 The fallback decision

```
captured = Resolved      -> use captured          provenance: captured
captured = Ambiguous     -> api = ERROR           NO fetch is issued
captured = Unavailable:
     apiSource declared  -> fetch
          2xx + JSON     -> use fetched           provenance: fetched
          anything else  -> api = ERROR, with an actionable reason
     apiSource absent    -> api = ERROR           (existing message)
```

**Ambiguity never falls back.** Two captured responses matched and the
declaration does not say which; issuing a third request and preferring
it would silently answer a question the platform elsewhere refuses to
answer, and would let the runner's own fetch override two responses the
application actually received. Asserted by
`api_acquisition_test.dart`, which also asserts the fetcher was called
**zero** times.

### 3.4 Provenance is always recorded

Every `api-to-ui` result carries which source it rests on:

```
responseProvenance   captured | fetched
responseEndpoint     GET /products/123
fallbackReason       <why capture did not supply it>    (fetched only)
```

A reader must never have to guess whether a PASS was measured against the
application's own traffic or against a request the runner made. A PASS
resting on a fetch is a weaker claim, and the report says which it is.

---

## 4. Figma acquisition

`figmaSource:` is resolved once per screen at run start through the
**existing** `FigmaClient`, its on-disk cache at `<project>/figma/.cache`,
and the existing `FigmaNormaliser`. There is no second Figma
integration. `FigmaTarget.parseUrl` already translates the URL's
`node-id=913-1` into the API's `913:1`.

Cache-backed rather than always-refetch: Figma rate-limits, a design does
not change between two steps of one run, and a milestone named for
determinism should not let two runs of one test see different designs.

**A declared `figmaSource:` wins over an on-disk `figma/<screen>.json`**,
and the run says so:

```
figma: "/product/details" uses the declared figmaSource, not the spec on disk
```

A stale on-disk spec silently shadowing a URL somebody declared is
exactly the quiet wrongness this platform exists to avoid. This was not
hypothetical — see §9.2.

**The node-id → semantic-id mapping stays mandatory.** Real frames name
their layers `Frame 42980`, `Rectangle 91`, `Component 3`. Inferring
identifiers from those produces something that looks like it works and is
wrong. A `figmaSource:` whose mapping file is missing yields **figma =
ERROR**, naming the file — not a skip, because a design *was* declared
and the run could not honour the declaration.

Invalid token, unreachable file, missing node, rate limit: **figma =
ERROR** carrying `FigmaClient`'s existing typed message, which names the
file key and the status and has never echoed the token.

---

## 5. UI evidence

Unchanged from E-03/E-04. The hybrid element+semantics tree over the VM
Service: `testId`, type, `text`, `enabled`, `visible`, `LogicalRect`
bounds, children, semantics. Property reads go through `readPropertyOf`,
which returns `PropertyAmbiguous` rather than guessing when one test id
is on two elements.

---

## 6. The result model

### 6.1 Five verdicts

`ui`, `api`, `figma`, `visual`, and `OVERALL`.

The milestone named three. `visual` is included because it was **already**
a distinct dimension of this platform: its own step flag
(`ValidateScreenStep.visual`), its own validator (`VisualValidator`,
deliberately not a `ScreenValidator`), its own config block with its own
tolerances and ignore regions, its own on-disk store (`visual_baselines/`,
`BaselineStore`), and its own enablement rule (`runsVisual(hasBaseline:)`).
Leaving it out of the block that claims to explain the verdict, while it
still affects that verdict, would be the hiding this milestone exists to
prevent.

### 6.2 How a result is classified

Declared by the validator that produced it, never inferred at report time
from the validator's name. The producing code is the only code that knows
what it actually compared.

> **A result belongs to the dimension of the source of truth it was
> comparing the UI against — except when the comparison never happened
> because UI evidence was missing or ambiguous, which belongs to `ui`.**

| Result | Dimension |
|---|---|
| `ui-presence`; the **execution outcome** of any flow step, `expectApi` and `validateScreen` included | ui |
| `api-to-ui` value match / mismatch; mapped element absent; response missing | api |
| `expectApi` **assertion** outcomes — the `ApiExpectationOutcome`, not the step's execution | api |
| `rules` — condition from the response, expectation on the UI | api |
| the 16 `figma-*` ids | figma |
| `visual` | visual |
| **no UI tree captured** (api-to-ui, rules, figma) | **ui** |
| **`PropertyAmbiguous`** — one test id on two elements (api-to-ui, rules, `figma-identity`) | **ui** |

**A step that measures something produces two results, and they are stamped
separately** — because they answer two different questions. "Did the
user-written step execute?" is a question about the flow, and
`ValidationDimension.ui` is defined as *"the user-written steps, and the
readability of the UI itself"*. "What did it find?" is a question about a
source of truth, and the rule above decides it.

| Step | Execution outcome | Finding |
|---|---|---|
| `expectElement` | ui | the outcome *is* the finding — it was measured against the UI |
| `expectApi` | ui | api — the `ApiExpectationOutcome`, measured against the response |
| `validateScreen` | ui | ui / api / figma / visual, each stamped by the validator that produced it |

So one failed `expectApi` reports **UI FAIL and API FAIL**: the flow stopped
at that step, *and* the response contradicted what was declared. Those are
two facts, not one fact counted twice, and dropping either loses something a
reader needs. `validateScreen` behaves the same way: a screen that fails only
a Figma check reports FIGMA FAIL for the finding and UI FAIL for the step
that did not complete.

Neither is load-bearing for the verdict — `passed` reads `steps`, `screens`
and `apiChecks` directly, never the dimension block — so this affects what a
report can *say*, not what it decides.

`rules` is an API dimension because `Condition.evaluate` is handed
`response.readPath` and has no access to the UI snapshot at all. A rule is
structurally *"API satisfies condition ⇒ UI must show expectation"* — an
API→UI consistency statement in conditional form. This is read off the
implementation, not off the validator's name: were a condition ever able
to read a UI property, `RulesValidator.dimension` is the one place that
would change with it.

Six sites override their validator's default. They are listed in the
spec, §8.

### 6.3 Aggregation

E-03's precedence, within a dimension and then across them:

```
ERROR > FAIL > PASS > SKIP
```

`SKIP` last does the work: **a dimension that was never checked reports
SKIP, never PASS.** A PASS is a positive claim and a claim needs
something to have been compared. `ERROR` outranking `FAIL` preserves
E-04: a run that could not answer the question must not read as one that
answered it.

### 6.4 It cannot drift

`RunResult.dimensions` is a **computed** getter — a pure function of the
`steps`, `screens` and `apiChecks` already on the result. No new stored
state, no second place a verdict is decided. The block cannot disagree
with `passed`, because it is derived from the same fields.

Pinned by a property test over every combination:

```
RunResult.passed   ⟺   overall ∈ { PASS, SKIP }
```

Stated that way rather than `overall == PASS` because a run in which
nothing was checked passes vacuously and rolls up to SKIP — consistent
with `SuiteVerdict.skip` already exiting 0.

`result.json` schema goes **1.0 → 1.1**, purely additively: every key
that existed at 1.0 keeps its meaning.

---

## 7. Credential handling

- **Secrets are a neutral primitive.** `SecretRef` / `Secret` /
  `SecretResolver` moved from `src/auth/` to
  **`src/secrets/`**. The dependency runs one way — `auth/` imports
  `secrets/`, never the reverse — so E-06 does not depend on
  authentication code.
- `SecretRef` is *where* a credential lives; `Secret` is *what* it is,
  and its `toString()` is `[REDACTED]`, so interpolation — the way a
  secret actually escapes, through an error message somebody added in a
  hurry — yields the marker.
- **A literal token is refused at parse time**, in both `apiSource:` and
  `figmaSource:`.
- The value is resolved once, immediately before the request, placed
  directly into the header, and not retained.
- **Headers never enter `ApiResponsePayload`**, in either direction.
  Request headers would carry the authorization; response headers would
  carry `set-cookie`. Neither can reach a report because neither enters
  the model.
- Error messages name the endpoint and the status, never a header. URLs
  in error messages are stripped of their query, which can carry a
  credential of its own.

Proven by `e06_credential_leakage_test.dart` (8 tests), which starts with
a canary asserting the check itself can fail — without it, every
assertion would pass on an empty string and prove nothing.

---

## 8. PASS / FAIL / ERROR / SKIP

Unchanged from E-04, and now reported per dimension.

| | Means | Example |
|---|---|---|
| PASS | Compared, and it matched | `response.price matches product.price.text` |
| FAIL | Compared, and it did not | `width is 345.8px but the design specifies 362.0px` |
| ERROR | Could not compare | `the Figma token env:FIGMA_TOKEN resolved to nothing` |
| SKIP | Nothing asked for | `nothing was checked in this dimension` |

Every non-PASS carries an actionable reason. Environmental problems stay
ERROR and never become FAIL.

---

## 9. The ExternalApp demonstration — what was and was not done

### 9.1 What was NOT done

**The ExternalApp demonstration required by §15 was not performed.** No UAT
credentials were available in this session, and authentication remains a
manual prerequisite by design (E-04 §2, `HUMAN_ACTION`). Five acceptance
criteria are therefore **NOT MET** and are listed as such in §11.

What follows is a genuine end-to-end demonstration against
`examples/ecommerce_app` on the **real Samsung SM-M127G**
(`RZ8T11QETWM`), against the **real Figma frame** `913:1` of
`<redacted>` fetched from the real Figma REST API. It is
**not** the ExternalApp demonstration, and the two are not blurred.

### 9.2 The run

```
$ export EXAMPLE_MOCK_BASE=http://127.0.0.1:8080
$ dart run packages/flutter_testsmith_cli/bin/testsmith.dart run \
    examples/ecommerce_app/tests/product_three_way.yaml \
    --fixture default --mock-api 8080
```

```
  figma: "/product/details" uses the declared figmaSource, not the spec on disk
  › launch the app
  › wait for the screen to settle
  › tap "login.submit"
  › expect to be on "/home"
  › wait for the screen to settle
  › tap "home.open_product"
  › expect to be on "/product/details"
  › wait for the screen to settle
  › validate the screen (automatic)

  UI       FAIL    validation failed: 5 failed, 0 errored
  API      PASS
  FIGMA    FAIL    "product.image" does not match the design: width is 345.8px
                   but the design specifies 362.0px (16.2px out, tolerance 2.0px)
  VISUAL   SKIP    no screenshot baseline for "/product/details" yet
  OVERALL  FAIL

  /product/details  FAIL  42 ok, 5 failed, 5 skipped, 0 errored
```

**API is PASS.** Four API→UI comparisons matched, against the response the
application itself received — no outbound request was issued by the
runner, because the capture supplied what the screen declared it needed.

**FIGMA is FAIL, and these are real.** Five geometry deviations, each
quantified against the 2px tolerance the project declared. They are
**pre-existing**: a control run with `figmaSource:` commented out, using
the committed on-disk spec, produces four of the same five.

The fifth — `product.image` — appears **only** when the design is fetched
fresh. The committed `figma/product_details.json` predates the
`clipsContent` field, so the stale spec on disk was comparing against a
frame that does not clip when the real one does. Declaring the source
surfaced a stale artefact that had been quietly weakening the check. That
is the §4 precedence rule earning its place on its first real run.

**The tolerance was not touched.** Loosening `positionPx`/`sizePx` to
turn this green is precisely what §9 of the milestone forbids, and it was
not done. The example application genuinely does not match its design at
the tolerance this project declared.

### 9.3 The deliberate failure

Same flow, same device, a fixture whose API disagrees with what the UI
renders:

```
$ dart run packages/flutter_testsmith_cli/bin/testsmith.dart run \
    examples/ecommerce_app/tests/product_three_way.yaml \
    --fixture product_empty_name --mock-api 8080
```

```
  ✗ api-to-ui product.name: product.name.text does not match response.name.
      API returned ; identity gives ""; the UI shows "Unnamed product".
  ✓ api-to-ui product.price: response.price matches product.price.text
  ✓ api-to-ui product.add_to_cart: response.available matches product.add_to_cart.enabled

  UI       FAIL    validation failed: 6 failed, 0 errored
  API      FAIL    product.name.text does not match response.name. API returned ;
                   identity gives ""; the UI shows "Unnamed product".
  FIGMA    FAIL    (the same five geometry deviations, unchanged)
  VISUAL   SKIP
  OVERALL  FAIL
```

The API dimension flipped PASS → FAIL on its own, carrying the full
**raw API value → transformation → UI value** chain that distinguishes a
data bug from a formatting bug. The FIGMA dimension held at exactly the
same five failures. **The dimensions move independently**, which is the
property §7 and §22 of the milestone ask for.

---

## 10. Regression

Recorded 2026-09-15, on the working tree at the end of this milestone.

| Suite | Baseline | After | Command |
|---|---|---|---|
| root | 22 | 22 | `dart test` |
| `flutter_testsmith_protocol` | 96 | 96 | `cd packages/flutter_testsmith_protocol && dart test` |
| `flutter_testsmith_engine` | 940 | **1009** | `cd packages/flutter_testsmith_engine && dart test` |
| `flutter_testsmith_cli` | 197 | **203** | `cd packages/flutter_testsmith_cli && dart test` |
| `figma_client` | 78 (+3 skip) | 78 (+3 skip) | `cd integrations/figma_client && dart test` |
| `ai_client` | 20 | 20 | `cd integrations/ai_client && dart test` |
| **total** | **1353** | **1428** | +75 new, 0 deleted, 0 weakened |

```
$ dart analyze --fatal-infos
No issues found!
```

Package boundaries (`flutter_testsmith` must not depend on `flutter_testsmith_engine`;
`flutter_testsmith_engine` must not depend on Flutter) are enforced by
`test/packaging_test.dart` and `test/external_consumer_test.dart` — both
pass.

`docs/evidence/*.md` differ from HEAD only in a generation timestamp, and
that change predates this milestone. No matrix row changed.

---

## 11. Acceptance

**MET** means the code exists, a named test passes, and the command that
produced the evidence is recorded.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | User can write/define a test case | MET | `tests/product_three_way.yaml` + `mappings/product_details.yaml` |
| 2 | Existing DSL reused where possible | MET | no change to `test_flow.dart`; zero new steps |
| 3 | Runner executes the user-written test | MET | §9.2 run |
| 4 | API dev URL/endpoint configurable | MET | `api_source_test.dart` (10) |
| 5 | API token securely configurable | MET | `api_source_test.dart`, `e06_credential_leakage_test.dart` |
| 6 | API response obtained deterministically | MET | `api_acquisition_test.dart` (10) |
| 7 | API fields mapped to UI properties | MET | pre-existing `mappings.dart`; §9.2 |
| 8 | API→UI matching works | MET | §9.2, API PASS with 4 comparisons |
| 9 | API→UI mismatch produces FAIL with explanation | MET | §9.3 |
| 10 | Figma Dev URL configurable | MET | `figma_source_test.dart` (6) |
| 11 | Figma token securely configurable | MET | `figma_source_resolver_test.dart` (6) |
| 12 | Figma frame/node identifiable | MET | §9.2 resolved `913:1` |
| 13 | Figma design obtained deterministically | MET | cache-backed; `figma_source_resolver_test.dart` |
| 14 | Figma properties mapped to UI properties | MET | pre-existing node-id mapping; §9.2 |
| 15 | Figma→UI matching works | MET | §9.2, 35 figma checks passed |
| 16 | Figma→UI mismatch produces FAIL with explanation | MET | §9.2, 5 quantified deviations |
| 17 | Flutter UI inspected deterministically | MET | §9.2, 42 checks over the real tree |
| 18 | UI result reported independently | MET | `dimension_verdict_test.dart` (16) |
| 19 | API result reported independently | MET | §9.2 API PASS while FIGMA FAIL |
| 20 | Figma result reported independently | MET | §9.3 FIGMA unchanged while API flipped |
| 21 | Overall result deterministic | MET | `dimension_verdict_test.dart` |
| 22 | A failure cannot be hidden by a passing dimension | MET | `dimension_verdict_test.dart`, all 4 dimensions |
| 23 | ERROR/SKIP remain distinct from FAIL | MET | `aggregateStatus`; §9.2 VISUAL SKIP |
| 24 | Unknown mappings cannot silently pass | MET | pre-existing; `validators.dart` |
| 25 | Missing evidence cannot silently pass | MET | SKIP-never-PASS rule, `dimension_verdict_test.dart` |
| 26 | API credentials never exposed | MET | `e06_credential_leakage_test.dart` (8) |
| 27 | Figma credentials never exposed | MET | same, plus `token_redaction_test.dart` |
| 28 | E-04 testability reporting intact | MET | §10; `passed ⟺ overall ∈ {PASS,SKIP}` property test |
| 29 | **ExternalApp demonstrates a real complete flow** | **NOT MET** | no UAT credentials this session |
| 30 | **ExternalApp demonstrates API PASS** | **NOT MET** | " |
| 31 | **ExternalApp demonstrates Figma PASS** | **NOT MET** | " |
| 32 | **ExternalApp demonstrates UI PASS** | **NOT MET** | " |
| 33 | **ExternalApp demonstrates overall PASS** | **NOT MET** | " |
| 34 | A deliberate API or Figma mismatch produces a deterministic FAIL | MET | §9.3 |
| 35 | No AI functionality implemented | MET | `ai_boundaries_test.dart` passes; nothing added calls `ai_client` |
| 36 | No E-05 authentication automation implemented | MET | `secrets/` relocation only; no auth flow touched |
| 37 | No autonomous exploration implemented | MET | nothing added explores |
| 38 | No commit/push without approval | MET | nothing committed; working tree only |

**33 MET, 5 NOT MET.**

A further caveat on #31 and #33, stated plainly: even on
`examples/ecommerce_app`, **Figma PASS and overall PASS were not
demonstrated**, because the example application genuinely deviates from
its design at the 2px tolerance the project declares (§9.2). The
machinery is shown working — 35 Figma checks pass, 5 fail with quantified
reasons — but a clean all-green three-way run is not among the evidence
here, and the tolerance was not relaxed to manufacture one.

---

## 12. Known limitations

1. **Row 2 of §3.2 takes the first match silently.** `api: GET /x` picks
   the earliest matching completed exchange where `usesResponseFrom:`
   would refuse two. Pre-existing; unchanged deliberately, because
   changing it would turn passing runs into errors. Declaring
   `usesResponseFrom:` removes the ambiguity.
2. **A fetched response is not the response the application saw.** When
   the fallback fires, the comparison is against a request the runner
   made, which a stateful backend may answer differently. This is why
   capture is preferred and why provenance is always recorded.
3. **The Figma cache can serve a stale design.** Deliberate, for
   reproducibility. `testsmith figma pull --refresh` is the escape.
4. **A committed `figma/<screen>.json` can be stale in a worse way** — it
   can predate fields the model has since gained, as
   `product_details.json` predates `clipsContent` (§9.2). Declaring
   `figmaSource:` is the fix; the on-disk path remains supported.
5. **The node-id → semantic-id mapping is still hand-written.** Nothing
   in this milestone infers it.
6. **`visual` remains opt-in on a first run**, because it writes a file
   into the repository.
7. **`/checkout`'s design spec is synthetic** (node `2100:0001`), not a
   real pulled frame. Only `/product/details` is validated against a real
   design.
8. **iOS remains out of reach** on this host.
