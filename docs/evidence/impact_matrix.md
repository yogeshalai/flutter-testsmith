# Test selection, stressed

Generated from `testsmith impact --changed <path>` against the real
seven-screen example application, on 324bc60.

| Changed file | Selected | Skipped | Reason |
|---|---|---|---|
| `examples/ecommerce_app/lib/product_details_screen.dart` | 4 | 2 | 4 of 6 flow(s) selected from 1 changed file(s) |
| `examples/ecommerce_app/lib/screens/cart_screen.dart` | 1 | 5 | 1 of 6 flow(s) selected from 1 changed file(s) |
| `examples/ecommerce_app/lib/screens/checkout_screen.dart` | 1 | 5 | 1 of 6 flow(s) selected from 1 changed file(s) |
| `examples/ecommerce_app/mappings/cart.yaml` | 1 | 5 | 1 of 6 flow(s) selected from 1 changed file(s) |
| `examples/ecommerce_app/lib/app.dart` | 6 | 0 | running everything: examples/ecommerce_app/lib/app.dart can reach any screen, so no flow can be ruled out |
| `examples/ecommerce_app/lib/widgets/async_view.dart` | 6 | 0 | running everything: nothing is known about examples/ecommerce_app/lib/widgets/async_view.dart, so no flow can be ruled out |
| `examples/ecommerce_app/pubspec.yaml` | 6 | 0 | running everything: examples/ecommerce_app/pubspec.yaml can reach any screen, so no flow can be ruled out |
| `packages/flutter_testsmith_engine/lib/src/dsl/steps.dart` | 6 | 0 | running everything: packages/flutter_testsmith_engine/lib/src/dsl/steps.dart can reach any screen, so no flow can be ruled out |
| `docs/ARCHITECTURE.md` | 0 | 6 | only documentation changed (1 file(s)), which cannot alter behaviour |

## The brief's question, answered

> Change ProductDetails. Determine whether the system selects
> ProductDetails tests, Cart tests, Checkout tests, and avoids unrelated
> tests where safe.

**ProductDetails tests: yes.** All four flows that reach
`/product/details` are selected, each with the specific overlap named -
`touches .../product_details_screen.dart (/product/details,
product.unavailable, product.add_to_cart)`.

**Cart and Checkout: only through the journey.** `full_journey`
traverses both and is selected, so both screens *are* exercised. A
cart-only flow is not selected, and the reason is positive evidence
rather than an omission: nothing in `product_details_screen.dart`
declares a cart screen or a cart element.

**Is that safe?** For the failure modes this attribution can see, yes.
For one it cannot: attribution is by *declaration*, not by navigation.
If ProductDetails were changed so that its Add to Cart pushed the wrong
route, a cart-only flow entering the cart another way would still pass -
and the journey would catch it. The platform is therefore safe here
because a journey flow exists, not because the analysis understands the
edge. That is a real limit, recorded in the acceptance report.

**Unrelated tests are avoided.** `home` and `cart_empty` are skipped for
a ProductDetails change; `product_details` is skipped for a cart change.

## What selects everything, and why

Four distinct reasons, each reported as itself rather than as a generic
fallback:

| Cause | Message |
|---|---|
| the router or entry point | *can reach any screen* |
| a manifest, asset or platform folder | *can reach any screen* |
| the test platform's own source | *can reach any screen* |
| a file the index cannot account for | *nothing is known about it* |

The last one is the safety net, and Phase 12 found it had a hole: a file
whose every test id is built by interpolation - `TestKey('$idPrefix.loading')` -
matched the pattern and yielded ids no flow can ever name. The file then
looked *accounted for*, and the analyser excluded every flow on evidence
that was fake. Measured before the fix: the shared `AsyncView`, which can
reach the loading, error and empty state of every screen in the
application, selected **0 of 6 flows**. It now selects all six.
