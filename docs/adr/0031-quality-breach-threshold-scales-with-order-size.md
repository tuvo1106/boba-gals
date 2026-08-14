# ADR-0031: The quality-breach threshold scales with order size

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §9.6
- **Relates to:** ADR-0014, ADR-0024

## Context

ADR-0024 shipped the live quality timer against a single flat `quality_limit_seconds`
(default 300s) per store, and flagged its own known limitation rather than block on it:
ADR-0014's cohesion-boost measurements already showed p90 spread — the time between an
order's first and last drink finishing — running 943s-7505s for orders of 3+ drinks, 3x-25x
past the 300s limit. Against a flat number, the marker firing on a multi-drink order isn't
an unusual-slowness signal; it's close to the default outcome. Tracked as issue #80 rather
than blocking ADR-0024's merge, since the flat-threshold version still did §9.6's one job —
a check-in/remake prompt — just less precisely than it could.

§9.6 as written names `quality_limit_seconds` as *the* mechanism: "breach when sitting time
exceeds `quality_limit_seconds` (default 300)." ADR-0024 already established the precedent
for implementing §9.6 with a documented deviation — measuring against `now` rather than
`picked_up_at`, which no live pickup signal in this codebase can observe — via an ADR
rather than a DESIGN.md rewrite. This decision follows the same precedent: DESIGN.md is not
edited; this ADR records the size-aware refinement instead.

## Decision

Learn a per-size-class baseline spread, the same way `PrepTimeStat`/`RecordPrepTime` learn
per-menu-item prep durations (§7.3), and check each drink against its own order's size
class instead of one flat number.

**Scoped per store, not global.** `PrepTimeStat` is scoped per menu item because prep time
is a fixed physical property of a drink — two stores selling the same Thai Tea share
roughly the same prep time. Spread is a queue-dynamics property: it depends on a store's own
staffing and demand, which two stores do not share even for the same size class. The new
`QualitySpreadStat` model is keyed on `(store_id, size_class)`.

**The learned threshold is the class's own mean plus 1.28 standard deviations** — a normal
approximation of the 90th percentile — rather than a flat multiplier over the mean.
`ewma_variance` is already tracked exactly this way by `PrepTimeStat`/`RecordPrepTime`
(§7.3's own comment: "knowing which items are erratic rather than merely slow" is what a
blunt multiplier can't do); `QualitySpreadStat` reuses the same machinery. "Breach" becomes
"this drink is sitting past the worst decile for orders its size," not an arbitrary
multiple of an average.

**Seeded multipliers over `quality_limit_seconds`, not a blank slate.** Before a size class
has `QualitySpreadStat::MINIMUM_SAMPLES` (10) real samples, `SweepQualityBreaches` uses
`quality_limit_seconds × SEEDED_MULTIPLIERS[size_class]`:

| size class | seeded multiplier | resulting seconds (300s default) | ADR-0014 measured p90 |
|---|---|---|---|
| 1-2 | 0.5x | 150s | ~104-126s |
| 3-6 | 6.0x | 1800s | ~943-2001s |
| 7+ | 20.0x | 6000s | ~3159-7505s |

Each seeded value sits above the measured p90 range (roughly 1.2x headroom) so a breach
reads as "meaningfully beyond the ordinary spread for this size," not "typical." Expressed
as a multiplier over `quality_limit_seconds` rather than a hardcoded constant per class so
a store that has already tuned that config knob (§13.4's one existing lever for this
feature) gets a proportionally scaled answer for every size, instead of the knob doing
nothing until real per-store data accumulates.

**`RecordQualitySpread` has no outlier guard**, unlike `RecordPrepTime`. `RecordPrepTime`'s
`[0.25x, 4x]` band exists to catch a barista who forgot to tap "finish" — a data error, not
a real slow drink. There is no equivalent failure mode for `ready_at - first_ready_at`: both
timestamps are stamped automatically by `RollUpOrderStatus`, never by a tap that can be
missed, so every order that reaches `ready` produced a real observation. Real spread also
legitimately spans a wide range by nature of the problem — ADR-0014 measured p90s from
~100s to ~7500s+ across size classes alone — so there is no threshold that separates
"erroneous" from "a genuinely slow order" the way there is for a single drink's prep time.
An early implementation draft copied `RecordPrepTime`'s band directly and it silently
discarded every zero-spread sample from a single-drink order forever, once any EWMA
existed (`0 < ewma * 0.25` is always true for a positive EWMA) — caught before merge, not
shipped.

**Recorded the same way prep time is** — deferred by a full undo window
(`RecordQualitySpreadJob`, `UndoLastAction::WINDOW`) rather than at the moment an order
reaches `ready`, for the identical reason ADR-0019 gives for prep time: an EWMA can't be
cleanly un-blended, and the KDS undo can move an order back out of `ready`. `FinishDrink`
enqueues the job alongside the existing SMS and wait-metric calls, in the same
`if order.status == "ready"` block.

## Alternatives considered

| Option | Why not |
|---|---|
| A flat multiplier (e.g. 2x the mean) instead of mean + z·stddev | Arbitrary, and this repo already has the exact machinery (`ewma_variance`) to do better — reusing it costs nothing extra and gives a principled "worst decile" reading instead of a hand-picked number. |
| Global (menu-item-style) scope instead of per-store | Spread depends on a store's staffing and demand, not a fixed physical process. A global stat would blend a fast, well-staffed store's spread with a slow, understaffed one's, which is meaningless for either. |
| Reuse `RecordPrepTime`'s `[0.25x, 4x]` outlier band unchanged | Caught during implementation: it permanently rejects legitimate zero-spread samples once any EWMA exists, silently biasing the "1-2" class upward by excluding real single-drink orders forever. There is also no "forgotten tap" failure mode to guard against here in the first place. |
| Hardcoded seconds per size class instead of a multiplier over `quality_limit_seconds` | Would make the one existing admin config knob (§13.4) do nothing for any size class until real per-store learning kicks in, silently reducing operator control rather than extending it. |
| An admin endpoint exposing `QualitySpreadStat`, mirroring `GET /admin/prep_time_stats` | #80 doesn't ask for this, and it's a reasonable follow-up rather than part of closing the issue — no reason to bundle it in. |

## Consequences

Every store's breach behavior changes on deploy, immediately, via the seeded multipliers —
not just once learning kicks in. A 3+ drink order that would have flagged at 300s under the
old flat check now needs to sit 6x-20x longer before it's called unusual, which is the
entire point of #80, but it means historical breach-rate figures (dashboards, any
operational intuition built on "the marker fires around 5 minutes") are not comparable
across the deploy boundary.

`quality_limit_seconds` no longer means "the exact number of seconds before a breach" for
any size class — it's now a scaling base. An operator who wants to tighten sensitivity still
turns the same knob, but the resulting number for a given size class is no longer
directly legible from the config value alone without knowing the multiplier table above (or
once learned, the live `QualitySpreadStat` baseline, which has no admin surface yet — see
the alternatives table).

## Revisit when

`QualitySpreadStat` accumulates enough real per-store history that the seeded multipliers
matter only for a brand-new store's first ten or so multi-drink orders per size class —
worth checking the seeded-vs-learned split isn't dominated by seeded values indefinitely for
a low-volume store, which would mean `MINIMUM_SAMPLES` (10) is too high a bar relative to
real order volume. If an operator ever asks to see the learned baselines directly, that's
the trigger for the admin endpoint left out of scope here.
