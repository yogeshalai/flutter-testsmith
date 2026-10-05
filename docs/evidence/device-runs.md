# Device runs

Everything here was run on real hardware and a real emulator during
Phase 12. Nothing in this file is projected from a unit test.

## The devices

| | Physical | Emulator |
|---|---|---|
| Model | **SM-M127G** (Samsung Galaxy M12) | `sdk_gphone64_x86_64` |
| Serial | `RZ8T11QETWM` | `emulator-5554` (AVD `mytest_api33`) |
| Android | 13 (API 33) | 13 (API 33) |
| Resolution | 720x1600 | 1080x2400 |
| Density | 300 dpi | 420 dpi |
| devicePixelRatio | 1.875 | 2.625 |
| Logical viewport | 384x805 | 411x890 |

## 1. The channel, end to end

`testsmith smoke -d RZ8T11QETWM --tap-id login.submit --mock-api 8080`

```
  session          cd15cd79-7c61-4f95-8cb7-51be1fc30f41
  protocol         1.0
  capabilities     navigation, uiTree, network, screenshot
  app version      0.2.0
  build mode       debug
  dpr at attach    1.0    (may predate the first frame)
  dpr settled      1.875

  recovered from ring buffer   2
  arrived on live stream       9
  duplicates discarded         1
  distinct events              10
  history complete             yes

  ui tree nodes                17
  elements walked              365
  test ids found               4
  tapped                       PhysicalPoint(360, 518)

  API exchanges by screen
    /login   POST /auth/login   200
    /home    GET /home/summary  200

  screens visited  /login -> /home
PASS: channel verified end to end.
```

`capabilities` now includes **`screenshot`** - the `repaintBoundary`
capture path, which the protocol has declared since Phase 1 and which
nothing had ever served until Phase 12.

## 2. The whole shop

`testsmith run tests/journey.yaml -d RZ8T11QETWM --mock-api 8080`

Seven screens, seven API calls, one order placed. **102 deterministic
checks, 0 failed.**

| Screen | Result | Checks |
|---|---|---|
| `/home` | PASS | 3 ok, 0 failed, 3 skipped |
| `/products` | PASS | 14 ok, 0 failed, 2 skipped |
| `/product/details` | PASS | 47 ok, 0 failed, 3 skipped |
| `/cart` | PASS | 12 ok, 0 failed, 3 skipped |
| `/checkout` | PASS | 26 ok, 0 failed, 3 skipped |

```
mock API served
  200  POST /auth/login
  200  GET /home/summary
  200  GET /products
  200  GET /products/123
  200  GET /cart
  200  GET /cart
  200  POST /checkout
```

Each capability the brief asks about, exercised on the device:

| Capability | Evidence |
|---|---|
| launch | `flutter run --machine`, APK built and installed |
| attach | VM Service URI observed, DDS connected |
| handshake | protocol 1.0, session id, buffered history drained |
| navigation | `/login -> /home -> /products -> /product/details -> /cart -> /checkout -> /order/success` |
| UI inspection | 17-365 elements walked per screen, 4-49 retained |
| API capture | 7 exchanges correlated to the screen that made them |
| screenshot | `out/order-success.png`, `out/final/product-details.png` |
| tap by id | 6 taps, each resolved from bounds + the ratio in the same snapshot |
| validation | 102 checks across api-to-ui, rules, ui-presence, 6 figma checks, visual |

## 3. Fixture-driven flows

| Flow | Fixture | Result |
|---|---|---|
| `product_out_of_stock` | `product_out_of_stock` | **PASS** - 49 ok. Both rules fired: `product.unavailable` visible, `product.add_to_cart` disabled |
| `product_server_error` | `api_500_server_error` | **PASS** - the device really received a 500; the screen showed "our end" and `product.price` was absent |
| `cart_empty` | `cart_empty` | **PASS** - `home.cart_badge` reads "Cart (0)" and `home.open_cart` is disabled |

The mock API log confirms the fixture reached the device rather than the
runner assuming it:

```
  200  POST /auth/login
  200  GET /home/summary
  500  GET /products/123      <- api_500_server_error
```

## 4. Visual repeatability

Five runs of the **same unchanged screen**, each a fresh build, install,
launch and attach.

| Run | Differing | SSIM | Wall time | Verdict |
|---|---|---|---|---|
| 1 | 0.065% | 0.9987 | 42 s | pass |
| 2 | 0.065% | 0.9987 | 45 s | pass |
| 3 | 0.065% | 0.9987 | 42 s | pass |
| 4 | 0.065% | 0.9987 | 41 s | pass |
| 5 | 0.065% | 0.9987 | 41 s | pass |

**False positives: 0 of 5.** The measurement is identical to three
decimal places across every run, which is the property that matters:
the variance is zero, not merely small.

That constant 0.065% was then investigated rather than accepted. It is
**723 pixels in rows 1541-1572** - the Android navigation bar, which the
ignore regions did not cover. A third of the 0.2% whole-screen budget,
spent every run on something that is never a regression. After adding a
bottom-anchored ignore region:

| Run | Differing | SSIM |
|---|---|---|
| 6 (after the fix) | **0.000%** of 1,076,400 px | **1.0000** |
| 7 | **0.000%** | **1.0000** |

### The same seeded defect, three times

`--dart-define=SEED_PRICE_BUG=true`, which renders the price 400 lower
than the API returned.

| Run | Detected | Measurement | Wall time |
|---|---|---|---|
| 1 | yes | `product.price` differs by **17.901%** of its own area | 47 s |
| 2 | yes | **17.901%** | 38 s |
| 3 | yes | **17.901%** | 38 s |

**Detection: 3 of 3, identical to three decimal places.**

The per-element gate is what catches it. The same change is **0.04% of
the screen** - comfortably inside a whole-screen tolerance of 0.2% - and
**17.9% of the price element's own area**. One number cannot do this job.

### Timing sensitivity

Wall time varied 38-47 s across eight runs, dominated by build and
install rather than by measurement. The measured values did not move at
all across that spread, so the comparison is not timing-sensitive once
`waitForSettle` has returned. Step timings from one run:

```
  1 ms     launch the app
  3150 ms  wait for the screen to settle
  642 ms   tap "login.submit"
  974 ms   expect to be on "/home"
  1274 ms  wait for the screen to settle
  205 ms   tap "home.open_product"
  101 ms   expect to be on "/product/details"
  1554 ms  wait for the screen to settle
  1528 ms  validate the screen (automatic)
  708 ms   take a screenshot
```

## 5. The emulator, and how it differs

`testsmith run tests/product.yaml -d emulator-5554 --mock-api 8080`

**46 checks passed. 1 failed. The one that failed is the one that
should have.**

| | Physical | AVD | Same? |
|---|---|---|---|
| Launch, attach, handshake | ok | ok | yes |
| Navigation events | ok | ok | yes |
| UI tree capture | ok | ok | yes |
| API capture and correlation | ok | ok | yes |
| Tap by semantic id | ok | ok | yes |
| `api-to-ui`, `rules`, `ui-presence` | pass | pass | yes |
| **Figma structural checks** | pass | pass | **yes** |
| **Visual comparison** | pass | **fail** | **no** |
| First settle | 3150 ms | 5148 ms | slower |
| Whole flow | 10.1 s | 10.0 s | same |

```
✗ visual: "/product/details" the screenshots are different sizes:
  baseline is 720x1600, this run captured 1080x2400. Nothing was
  compared.
```

Two things worth stating plainly.

**Structural validation is device-portable.** Every Figma geometry,
typography and colour check passed unchanged on a device 50% wider and
40% denser, because the design is *projected* onto whatever viewport the
device reports rather than compared in absolute coordinates. That is the
projection layer earning its place.

**Visual comparison is not, and the platform says so rather than
guessing.** It refuses, names both resolutions, and reports that nothing
was compared - instead of resampling and producing a number that means
nothing. A baseline belongs to one device profile. Extending the
per-fixture baseline variant to cover device profile is the obvious next
step and is not done.

## 6. Screenshot capture paths, measured

| | `screencap` | `surface` |
|---|---|---|
| Size | 720x1600 | 720x1510 |
| Bytes | 56,286 | 49,200 |
| Contains system bars | yes | no |
| Two runs, same screen | 0.000%, ssim 1.0000 | 0.000%, ssim 1.0000 |

Mixing them is refused:

```
! visual: the baseline was captured by deviceScreencap but this run
  captured by repaintBoundary. These are different pictures of the same
  screen and comparing them would report a change that did not happen.
  Re-record the baseline.
```

See [ADR-0010](../adr/0010-screenshot-capture.md) for what each path
excludes and why neither is a Figma comparison.

## 7. Secrets, in the artefacts a real run produced

Every seeded credential, grepped in `out/result.json` and
`out/report.html` after the seven-screen journey:

| Secret | Where the app puts it | `result.json` | `report.html` |
|---|---|---|---|
| `SEEDED_PASSWORD_c41e77b0` | login request body | 0 | 0 |
| `SEEDED_ACCESS_TOKEN_8a17fc` | login response, then every later header | 0 | 0 |
| `SEEDED_REFRESH_TOKEN_20b93e` | login response body | 0 | 0 |
| `4111111111111111` (card) | checkout request body | 0 | 0 |
| `731` (CVV) | checkout request body | 0 | 0 |
| `884512` (OTP) | checkout request body | 0 | 0 |
| `DEVICE_SECRET_9f2a41c8` | every request header | 0 | 0 |
| `MOCK_SESSION_SECRET` | every response `set-cookie` | 0 | 0 |
| `Bearer ` | authorization header | 0 | 0 |

Zero occurrences, and for **two independent reasons** - worth separating,
because only one of them is redaction:

1. Redaction runs at capture, in-process, before an event is emitted.
   Proven directly in `secret_leakage_test.dart`, which searches the
   serialised event for the literal.
2. `ExchangeSummary` - what `result.json` carries - has fields for
   method, path, status and duration, and none a body could occupy.

## Reproducing

```bash
testsmith doctor
testsmith smoke   -d RZ8T11QETWM --tap-id login.submit --mock-api 8080
testsmith run examples/ecommerce_app/tests/journey.yaml -d RZ8T11QETWM --mock-api 8080
testsmith run examples/ecommerce_app/tests/product_out_of_stock.yaml -d RZ8T11QETWM --mock-api 8080
testsmith run examples/ecommerce_app/tests/product_server_error.yaml -d RZ8T11QETWM --mock-api 8080
testsmith run examples/ecommerce_app/tests/cart_empty.yaml -d RZ8T11QETWM --mock-api 8080
testsmith run examples/ecommerce_app/tests/product.yaml -d RZ8T11QETWM --mock-api 8080 \
    --dart-define=SEED_PRICE_BUG=true
```
