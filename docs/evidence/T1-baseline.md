# T1 - Baseline, before any Phase 12 change

Recorded 2026-09-12 07:46 UTC, commit e7c41a4.

## Dependency rules
```
ok  flutter_testsmith_protocol does not depend on: flutter, flutter_testsmith, flutter_testsmith_engine, flutter_testsmith_cli
ok  flutter_testsmith does not depend on: flutter_testsmith_engine, flutter_testsmith_cli
ok  flutter_testsmith_engine does not depend on: flutter, flutter_testsmith
ok  no Flutter import in flutter_testsmith_engine sources

All dependency rules hold.
```

## Test counts

| Package | Command | Result |
|---|---|---|
| `packages/flutter_testsmith_protocol` | `dart test` | +96: All tests passed! |
| `packages/flutter_testsmith_engine` | `dart test` | +325: All tests passed! |
| `packages/flutter_testsmith_cli` | `dart test` | +9: All tests passed! |
| `integrations/figma_client` | `dart test` | +37: All tests passed! |
| `integrations/ai_client` | `dart test` | +20: All tests passed! |
| `packages/flutter_testsmith` | `flutter test` | +176: All tests passed! |
| `examples/ecommerce_app` | `flutter test` | +7 -3: Some tests failed. |

**670 tests, 667 pass, 3 fail.** The README's "all 11 phases complete" was
written over a red suite.

## D-01 - three failing tests in the example application

```
type 'TextButton' is not a subtype of type 'FilledButton' in type cast
  test/widget_test.dart:76  disables add to cart when the API says unavailable
  test/widget_test.dart:85  enables add to cart when available

Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<exactly 2 widgets with text "Rs 2,999">
  test/widget_test.dart:65  shows the name and formatted price
```

Cause: Phase 6 ("implement the design in the example app", `64f6423`)
changed `product.add_to_cart` from a `FilledButton` to a `TextButton` and
added a second price at the foot of the card. The widget test was not
updated and has been failing since. Nothing in CI catches it - `.github/`
holds no workflow that runs `flutter test` in `examples/`.

## D-02 - every committed proposal is unrunnable

The seven files in `tests/proposed/` each declare a precondition the
platform cannot arrange:

| Proposal | Declares it needs | Can the platform do it? |
|---|---|---|
| `api_404_not_found` | HTTP 404 for product 123 | No - the fixture always has 123 |
| `api_500_server_error` | HTTP 500 | No - the server can only return 200 or 404 |
| `api_timeout` | no response within 5s | No - no delay mechanism |
| `discount_exceeds_price` | `price:90, discount:120` | No - one static fixture file |
| `empty_highlights_list` | `highlights:[]` | No - **and no `highlights` field exists at all** |
| `malformed_response_missing_price` | JSON without `price` | No |
| `null_image_url` | `image:null` | No |

All seven are byte-identical apart from the name: same taps, same
`validateScreen`, same screenshot. Approving any of them would add a test
that runs against the default fixture under an edge-case name and passes -
the worst possible outcome, because it reports coverage that does not
exist.

This is the gap Phase 12 T3 closes.
