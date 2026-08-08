# ADR-0010: The fairness sweep holds offered load constant

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §10.3, §10.4, §10.5, §11

## Context

§10.4's headline experiment is "small-order p90 wait vs. concurrent large-order rate", with an
acceptance criterion in §11: *"Small-order p90 wait is flat (±15%) across large-order rates
0%–12%, under DRR, at 3 stations, default demand."*

Run literally — vary `large_order_rate` from 0 to 0.12, leave everything else alone — the
result does not come close:

| large% | DRR small p90 | FIFO small p90 |
|---|---|---|
| 0% | 122.6s | 130.1s |
| 6% | 251.1s | 423.7s |
| 12% | 549.7s | 1028.6s |
| | **+348%** | **+691%** |

DRR is clearly better than FIFO, and just as clearly not flat.

The reason is a confound in the sweep itself. Large orders average 14 drinks; small ones
average about 1.5. Raising the large-order share therefore raises *total work*:

| large% | drinks/day | ρ | ρ/(1−ρ) |
|---|---|---|---|
| 0% | 636 | 0.318 | 0.47 |
| 12% | 1184 | 0.595 | 1.47 |

Drink volume nearly doubles and utilisation almost doubles with it. By Kingman's
approximation, waiting time scales with `ρ/(1−ρ)`, which triples across the sweep — so roughly
3× of the observed rise is load, before any scheduler is involved.

**The experiment as specified measures saturation and fairness at the same time, and cannot
separate them.** No scheduling policy holds waits flat while the offered load doubles; that is
a capacity result, not a fairness one.

## Decision

**The sweep compensates the arrival rate so drinks per hour stays constant while the size
mixture varies.** `demand_multiplier` is set to `mean_order_size(0%) / mean_order_size(rate)`,
which holds ρ at ~0.30 across the whole sweep.

With load held constant, the design's claim appears:

| large% | DRR | FIFO |
|---|---|---|
| 0% | 120.6s | 128.4s |
| 6% | 143.1s | 223.5s |
| 12% | 156.6s | 257.2s |
| | **+30%** | **+100%** |

FIFO rises steeply — §10.4 predicted exactly that, and §11 says a FIFO line that *doesn't*
rise means the generative model isn't stressing the system. DRR is far flatter and at 12%
halves the wait.

This is the honest form of the experiment. Composition is the independent variable; load is a
control. Letting both move is the classic confound, and the fix is the classic one.

## Consequences

**§11's ±15% cannot be assessed at this sample size.** DRR gives ±30% under constant load, but
the run-to-run variance is larger than that difference. Over 40 seeds at 12% large orders:

```
mean 147.2s   sd 26.4s   range 99.8s – 211.3s
```

A single seed spans 76% of the mean. At the six seeds this suite averages, the 95% confidence
interval of the mean is **±21s, about ±14%** — so each endpoint of a "0% vs 12%" comparison
carries roughly that much uncertainty and the measured +30% could plausibly be anywhere from
+5% to +55%. **±15% sits inside the noise.** Any statement that it is or is not reachable
needs far more seeds than are run here.

The quantum sweep has the same problem and should be read as a direction, not as values:

| quantum | measured spread 0%→12% |
|---|---|
| 30s | 27% |
| 60s | 27% |
| 120s (default) | 30% |
| 240s | 37% |
| 400s | 47% |

The monotonic trend across five points is more believable than any individual figure, and it
matches §10.4's "if it slopes up, the quantum is too large". Whether the line plateaus near
27% or continues down is not resolvable at n=10.

**What the numbers do and do not support:**

| Claim | Confidence | Why |
|---|---|---|
| DRR beats FIFO on small-order p90 | **High** | Large effect (roughly 2× at 12%), same seeds both arms, consistent in direction at every seed tried |
| The sweep confounds load with composition | **High** | Arithmetic, not statistics — drinks/day 636 → 1184, ρ 0.318 → 0.595 |
| DRR's line is flatter than FIFO's | **High** | Paired comparison; day-to-day variance largely cancels |
| Any specific figure (156.6s, +30%) | **Low** | sd/mean ≈ 18%, n = 6 |
| ±15% is unreachable | **Not supported** | Inside the confidence interval |

Paired comparisons on identical seeds are the reliable output here. Absolute waits are not,
and should not be quoted as though they were.

**The generative model is unvalidated, and partial.** §10.3's distributions are the design's
assumptions rather than measurements from a real shop — §10.5's replay experiment ("feed
historical `scheduler_events` through the simulator to calibrate σ") is what would ground
them, and it is listed as later work. Until then even a perfectly-estimated number describes
the model, not the shop.

Four of §10.3's nine processes are also not yet in the loop: **remakes, pickup delay,
reneging, and order-ahead**. That matters for what can be concluded — the remake priority
floor (§6.4) is currently exercised only by unit tests, never in simulation, and §10.4's
reneged-orders metric cannot be produced at all. They are the first thing to add before the
ablation study (§10.5 #1) is run in anger.
