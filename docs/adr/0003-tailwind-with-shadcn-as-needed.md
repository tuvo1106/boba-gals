# ADR-0003: Tailwind for styling, shadcn/ui components à la carte

- **Status:** Accepted
- **Date:** 2026-08-06
- **Design reference:** DESIGN.md §9.3 (ordering), §9.4 (KDS), §9.5 (board), §10.6 (dashboard)

## Context

The design specifies one React codebase and one build (§9.3), but four surfaces with
almost nothing in common visually:

| Surface | What it demands |
|---|---|
| Ordering — kiosk | 64px minimum hit targets, on-screen keyboard, attract screen |
| Ordering — web | 44px minimum hit targets, phone and desktop |
| KDS (§9.4) | A vertical lane of large drink cards, bold short tokens, no dialogs |
| Board (§9.5) | Two columns readable at 15 feet — typography and layout, not components |
| Dashboard (§10.6) | A dense instrument panel: tabular-numeral monospace, hairline rules, one accent, no gradients |

A styling approach has to be settled at build step 1, when the ordering flow lands.
Retrofitting one across a codebase that already has three surfaces in it is expensive, and
step 1 is the last cheap moment to choose.

The specific question raised was whether to use shadcn/ui. That question decomposes: shadcn
is a CLI that copies Radix-based components into your repo as source, styled with Tailwind.
It is not a runtime dependency, and it is not usable without Tailwind. So the load-bearing
decision is Tailwind; shadcn is a follow-on.

## Decision

**Tailwind, project-wide, from build step 1.** Its utility model absorbs the variance
across the four surfaces better than a component library's defaults do — the board and KDS
need bespoke layout regardless, and a library's opinions would be something to fight there
rather than lean on.

**shadcn/ui à la carte, not wholesale.** Pull individual components only where they earn
their place:

- **Dashboard config rail (§10.6)** — Slider (quantum), Switch (aging, cohesion), Select
  (policy), Tabs, Tooltip, Table for the metric grid. This is squarely its vocabulary.
- **Ordering option groups (§9.3)** — `option_groups.min_select` / `max_select` maps onto
  RadioGroup and Checkbox, with Radix handling keyboard interaction and ARIA.

**Hand-roll the KDS and the board.** Neither has meaningful standard-control surface area,
and §9.4 explicitly rejects the confirmation dialogs a component library would tempt you
toward.

Do not run `shadcn add` across the registry. Every component pulled is source you own,
lint, and maintain forever.

**Hit-target sizing is its own layer, not per-component overrides.** Define kiosk and web
target-size tokens in the Tailwind theme and apply them at the call site. shadcn's defaults
sit around 36–40px, well under both the 64px kiosk floor and the 44px web floor (§9.3);
patching each component individually is how that requirement quietly rots.

Vendored shadcn source lives in `frontend/src/components/ui/` so it is obviously distinct
from code we wrote, and can be excluded wholesale if frontend coverage thresholds are added
later.

## Alternatives considered

| Option | Why not |
|---|---|
| shadcn wholesale — add the full registry up front | Thirty-odd files of code we now own and lint, most of it never rendered. Review noise with no benefit. |
| Radix primitives directly + CSS Modules, no Tailwind | Genuinely close. Same accessibility, no vendored files, no Tailwind commitment — at the cost of writing every style by hand. Rejected because roughly half the UI (board, KDS, lane ribbon) is bespoke either way, and Tailwind makes the other half materially faster without making the bespoke half worse. |
| Hand-rolled components on plain CSS | Most control, most work, and it re-solves keyboard and ARIA behavior badly. The option groups and dashboard controls are exactly where that goes wrong. |
| MUI / Chakra / Mantine | Runtime weight, and theming that actively fights §10.6's instrument-panel spec. Their defaults are tuned for 40px mouse targets, which is the opposite of the kiosk requirement. |

## Consequences

Accessibility on the two surfaces that need it — option groups and dashboard controls —
arrives largely for free via Radix. The dashboard's §10.6 aesthetic does not: shadcn's
default theme is neutral but recognizable, and getting to hairline-and-monospace means
overriding its CSS variables. Behavior is free; design is not.

The station lane ribbon — the signature element §10.6 says to build first — is custom SVG
or canvas no matter what is chosen here. No part of this decision helps with it.

Vendored components receive no upstream fixes. That is the trade shadcn makes on purpose,
and it is acceptable at the handful of components this calls for; it would not be at thirty.

Tailwind's cost is class-dense JSX. Mitigate by extracting components, not by reaching for
`@apply`, which reintroduces a stylesheet layer while keeping the utility indirection.

## Revisit when

The ordering app accumulates more hit-target and sizing overrides than the components they
wrap. That ratio inverting is the signal that shadcn is fighting the kiosk requirement
rather than serving it — at which point hand-rolled controls on the same Tailwind theme are
the cheaper path, and Tailwind itself stays.
