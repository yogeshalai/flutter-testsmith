# ADR-0004: Three-tier semantic test ID API

**Status:** Accepted
**Date:** 2026-09-10

## Context

The engine needs stable, meaningful identifiers for UI elements
(`product.add_to_cart`). The specification is explicit that developers must
not be required to replace every Flutter widget.

## Decision

Three mechanisms, in priority order.

| Tier | API | Use |
|---|---|---|
| 1 | `TestKey('product.name')`, a `ValueKey` subclass | Any widget accepting a key |
| 2 | `TestId(id: 'product.name', child: ...)` | Subtree scoping; widgets whose key is consumed internally |
| 3 | `Semantics(identifier:)`, existing keys, semantics labels | Third-party or unowned widgets |

## Rationale

No single mechanism covers every case:

- A key is free and idiomatic - `Text(x, key: TestKey('product.name'))` - but
  it marks exactly one widget, and some widgets consume their key internally
  or pass it to an unexpected element.
- A wrapper scopes a whole subtree and survives internal refactoring better,
  but costs one extra element and is more invasive to write.
- Neither works for widgets the team does not own, where semantics is the
  only available handle.

Offering all three means adoption can be incremental: start with keys, reach
for the wrapper where keys fall short, and fall back to semantics for
third-party widgets.

## Consequences

**Three resolution paths in the inspector**, which must be ordered
deterministically and documented. Tier 1 wins over tier 2 wins over tier 3, so
a single element can never resolve ambiguously.

**Guidance is required, not optional.** Given a choice, teams will mix
mechanisms inconsistently. The SDK documentation states the trade-offs plainly
and recommends `TestKey` as the default.

**Duplicate IDs are an error.** Two elements resolving to the same ID makes
every assertion about that ID ambiguous, so the inspector reports it as a hard
error rather than silently taking the first match.

## Alternatives considered

**Keys only.** Simplest, but leaves third-party widgets unaddressable.

**Wrapper widget only.** Uniform, but invasive - it is close to the "replace
every widget" outcome the specification rules out.

**Semantics only.** Non-invasive and accessibility-aligned, but semantics
loses widget type information and depends on annotation quality the test
author often does not control.
