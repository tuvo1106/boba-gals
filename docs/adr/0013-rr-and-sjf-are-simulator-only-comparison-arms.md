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

| Arm | small-order p90 | 7+ p90 | stale drinks | slow-drink penalty |
|---|---|---|---|---|
| FIFO | 1138s | **1304s** | **24.2%** | 1.02× |
| RR — equal turns | 616s | 4186s | 49.9% | **0.90×** |
| DRR — equal time | **499s** | 4950s | 45.3% | 1.28× |
| DRR + aging | 767s | 2975s | 36.6% | 1.06× |
| DRR + aging + cohesion | 736s | 3696s | 36.9% | 1.14× |
| SJF — mean-wait floor | 1262s | 2256s | 34.4% | 19.63× |

Size classes are keyed on the drinks the customer *ordered*, not the drinks made: a remake
appends to `items` (§5.2), and counting those moved remade 2-drink orders into the "3-6"
class. Remade orders carry extra work and §6.4's priority floor, so they are slow ones, and
dropping them out of "1-2" biased the headline optimistic by ~2%.

Three things fall out, two of them uncomfortable.

**The deficit is worth 19%, and was previously invisible.** RR → DRR moves small-order p90 from
616s to 499s at a cost of 18% on the catering tail. §6.1's claim holds. But it only shows up
with aging and cohesion held off on both sides — compared against *default* DRR, plain RR
looks 20% better, because aging is doing something else entirely.

**Aging costs small orders 54%.** 499s → 767s, buying back 40% of the catering tail. §6.2
presents aging as an anti-starvation guarantee rather than a tuning knob, and at `aging_rate:
0.15` it is the single largest effect in the ladder — larger than the deficit it is layered
on. That is a defensible trade, but it is not the trade §6.1 describes, and nothing currently
measures it.

**Cohesion does not reduce staleness.** §6.4 and §9.6 both say that is its purpose. Adding it
moves stale drinks 36.6% → 36.9% and the catering tail 2975s → 3696s — both *worse*, the
second by 24%. One load point and eight seeds is not enough to call it, and the effect is small
enough to be noise, but it is the wrong sign and it is the one claim §6.4 rests on. It needs
a dedicated sweep before `cohesion_enabled` is trusted, and this ADR does not settle it.

**SJF does not starve catering orders here** — 2256s against DRR's 3696s. The design's fear
assumes drink cost tracks order size, and in §10.3's menu the two are independent: a 20-drink
order draws from the same distribution as everyone else, so it has twenty chances to hold a
cheap drink. SJF starves *expensive drinks*, not *large orders*. It remains unshippable, but
the reason is narrower than §6.3 states, and a menu where catering orders skewed toward the
95s items would make it bite.

**Which the last column is the direct measure of.** The slow-drink penalty — how much longer a
small order queues when it ordered ≥90s drinks rather than ≤50s ones — separates SJF from
everything else by an order of magnitude (19.63× against 0.90–1.28×), and it is the only
figure here that still discriminates at the shop's default demand, where every wait
percentile agrees. RR's 0.90× is the cleanest statement of what it is: equal *turns* ignores
prep time entirely, so a slow drink is not penalised at all — it is simply served in its turn
while everyone behind it absorbs the cost.

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
