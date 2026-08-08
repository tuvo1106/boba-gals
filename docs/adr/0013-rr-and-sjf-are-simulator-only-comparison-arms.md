# ADR-0013: RR and SJF are simulator-only comparison arms

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §1, §6.3, §6.6, §10.5
- **Relates to:** ADR-0011

## Context

§10.5's ablation ran `FIFO → DRR → DRR+aging → DRR+aging+cohesion`. That ladder can show
*that* fair queuing helps, but not *which* part of it does, and it never bounds what the
fairness costs. Two arms were missing:

- **Plain round robin** — one drink per order per turn, `prep_seconds` ignored. DRR is RR plus
  the deficit, so RR is the only arm that isolates the deficit. FIFO shows that some fairness
  is needed; RR shows that *equal time* rather than *equal turns* is what the design is
  claiming, which only matters because the menu spans 40s to 135s (§1).
- **Shortest job first** — the mean-wait optimum, and therefore the floor DRR is paying
  against. Without it "DRR beats FIFO" is a comparison against the worst option rather than a
  position on a scale.

This became worth building only after ADR-0011. Before common random numbers, two runs at one
seed faced different demand, so a four-way comparison would have been four different days.

## Decision

Add `policy: :rr` and `policy: :sjf` to `Scheduler::Config::POLICIES`, dispatched by
`Scheduler.pick_arm`. Neither carries a deficit, ages, or coheres — deliberately: an arm that
kept part of what it is meant to isolate would prove nothing.

**Both are refused by `UpdateSchedulerConfig`.** `SCHEMA["policy"]` stays `%w[drr fifo]`. The
scheduler can execute four policies; the store can be set to two. SJF minimises mean wait by
starving whatever is expensive, and a policy with a known starvation mode must not be one
dropdown away from dispatching real drinks. `Scheduler::Config#validate!` raises on anything
outside `POLICIES`, so a mistyped sweep fails loudly instead of silently running as DRR and
reporting a null result.

## Consequences

Measured at 3 stations, demand ×2.0 (80% utilisation), 8 seeds, with ADR-0011's common random
numbers so every row is the same day:

| Arm | small-order p90 | 7+ p90 | stale drinks |
|---|---|---|---|
| FIFO | 1137s | **1249s** | **24.2%** |
| RR — equal turns | 607s | 4184s | 49.9% |
| DRR — equal time | **484s** | 4831s | 45.3% |
| DRR + aging | 756s | 2932s | 36.6% |
| DRR + aging + cohesion | 723s | 3599s | 36.9% |
| SJF — mean-wait floor | 1221s | 2242s | 34.4% |

Three things fall out, two of them uncomfortable.

**The deficit is worth 20%, and was previously invisible.** RR → DRR moves small-order p90 from
607s to 484s at a cost of 15% on the catering tail. §6.1's claim holds. But it only shows up
with aging and cohesion held off on both sides — compared against *default* DRR, plain RR
looks 20% better, because aging is doing something else entirely.

**Aging costs small orders 56%.** 484s → 756s, buying back 39% of the catering tail. §6.2
presents aging as an anti-starvation guarantee rather than a tuning knob, and at `aging_rate:
0.15` it is the single largest effect in the ladder — larger than the deficit it is layered
on. That is a defensible trade, but it is not the trade §6.1 describes, and nothing currently
measures it.

**Cohesion does not reduce staleness.** §6.4 and §9.6 both say that is its purpose. Adding it
moves stale drinks 36.6% → 36.9% and the catering tail 2932s → 3599s — both marginally
*worse*. One load point and eight seeds is not enough to call it, and the effect is small
enough to be noise, but it is the wrong sign and it is the one claim §6.4 rests on. It needs
a dedicated sweep before `cohesion_enabled` is trusted, and this ADR does not settle it.

**SJF does not starve catering orders here** — 2242s against DRR's 3599s. The design's fear
assumes drink cost tracks order size, and in §10.3's menu the two are independent: a 20-drink
order draws from the same distribution as everyone else, so it has twenty chances to hold a
cheap drink. SJF starves *expensive drinks*, not *large orders*. It remains unshippable, but
the reason is narrower than §6.3 states, and a menu where catering orders skewed toward the
95s items would make it bite.

## Alternatives considered

**Add WFQ instead.** The academically interesting arm — DRR approximates it, and ADR-0012
notes we have already paid its cost. Rejected for now: it answers "how close is DRR to the
fairness ideal", which is a smaller question than "what is the deficit for" and "what does
fairness cost", and it is much more code.

**Make the arms selectable on a store.** Simpler, one allowlist. Rejected: see above. FIFO is
selectable because §6.3 wants it as a production fallback; SJF has no such role.

**Keep them as throwaway scripts.** Rejected. They would not run the production scheduler
(§10.1's one rule), they would rot, and the numbers above would not be reproducible from the
dashboard by anyone reading this.
