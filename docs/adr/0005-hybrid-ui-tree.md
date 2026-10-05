# ADR-0005: Hybrid element + semantics tree walk

**Status:** Accepted
**Date:** 2026-09-10

## Context

The semantic UI tree is the platform's primary functional validation
mechanism - explicitly *not* screenshots. It must supply, per node:
`id, type, text/value, enabled, visible, bounds, children, semantics`.

Flutter exposes two candidate trees, and neither supplies all of that.

| | Element tree | Semantics tree |
|---|---|---|
| Widget type | yes | **no** |
| Key / test ID | yes | partial (`identifier`) |
| Geometry | yes, via `RenderObject` | yes |
| `enabled` / `checked` | **no** | yes |
| Accessible label | **no** | yes |
| Coverage | everything, thousands of nodes | only semantically relevant nodes |

## Decision

Walk the **element tree** as ground truth for type, test ID and geometry, then
**enrich** each retained node with its corresponding semantics data.

Retain a node if it has a test ID, is a known interesting type (`Text`,
`Image`, `TextField`, buttons, list and scroll containers, toggles), or
carries semantics. Otherwise flatten it and re-parent its children.

## Rationale

The field list is only satisfiable by combining both sources. Using semantics
alone would lose widget types and every non-semantic node; using elements
alone would lose `enabled` and accessible labels - and `enabled` is required
by the specification's own motivating example (`AddToCart` disabled when
`available == false`).

Flattening is what makes it shippable. A raw element tree for a typical screen
is thousands of nodes, the overwhelming majority pure layout scaffolding, and
sending that on every screen transition would be both slow and unreadable.

## Consequences

**Retention rules are a tuning surface.** Too aggressive and the tree stops
being a faithful record; too loose and payloads balloon (risk R4). Rules are
therefore configurable per project, with a node-count budget asserted in tests.

**Flattening changes the hierarchy**, so structural comparison against Figma
must compare *relative* ordering and containment, not raw depth.

**Semantics must be enabled** for the enrichment pass, which has a small cost.
The SDK enables it explicitly in test mode rather than relying on an
accessibility service being active.

**Bounds are logical pixels**, reported alongside `devicePixelRatio` so the
engine converts exactly once (ADR-0006).

## Alternatives considered

**Semantics tree only.** Smaller, cleaner, accessibility-aligned. Rejected: no
widget types, and coverage depends on annotation quality the test author does
not control.

**Element tree only.** Complete and precise. Rejected: no `enabled`, no
accessible label - both explicitly required.

**Reuse the DevTools widget inspector protocol.** Rejected: shaped for
interactive human debugging, carries far more than we need, and would couple
us to an internal protocol we do not control.
