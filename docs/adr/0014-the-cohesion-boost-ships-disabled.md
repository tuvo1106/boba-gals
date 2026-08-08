# ADR-0014: The cohesion boost ships disabled

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §6.2, §6.4, §6.6, §9.6, §10.4
- **Relates to:** ADR-0013

## Context

ADR-0013's ablation showed cohesion moving staleness and the catering tail slightly the wrong
way, over eight seeds at one load. Too small to act on, so it was recorded as unsettled.

Settling it changes the answer. Sweeping `cohesion_boost` from 0 to 4.0 over 20 seeds, the
metric that moves is `cohesion_spread` — §6.4's own quantity, `ready_at − first_ready_at`, how
long the earliest drink sat while the rest were made:

| `cohesion_boost` | spread p90 @ ×2.0 | spread p90 @ ×2.6 |
|---|---|---|
| off | **152s** | **113s** |
| 0.5 | 155s | 115s |
| 1.0 (was default) | 155s | 118s |
| 2.0 | 164s | 123s |
| 4.0 | 170s | 127s |

Monotone in dose, in the wrong direction, at both loaded conditions. Broken out by order size,
it is worse in every class that can have a spread at all — including the four-drink case §6.4
opens with:

| order size | ×2.0 off → on | ×2.6 off → on | n |
|---|---|---|---|
| 2 | 113s → 126s | 104s → 120s | ~3,200 |
| 3–6 | 943s → 988s | 1576s → 2001s | ~2,000 |
| 7+ | 3159s → 3458s | 6715s → 7505s | ~440 |

There is no regime in which it helps.

The implementation was verified before the design was blamed. `Flow#fraction_made` is
`made_count / total_items` against a 0.5 threshold, exactly as §6.2 specifies, and
instrumenting `quantum_for` shows the boost firing on 32–34% of multi-drink flow lookups at
load — reaching a real, bounded subset rather than nothing or everything.

## Decision

`cohesion_enabled` defaults to `false`, in `Scheduler::Config::DEFAULTS` and in `Store`'s
effective config. The code, the knob and §6.6's allowlist entry all stay.

**Why it backfires.** The boost accelerates orders *past* halfway, and the barista time it
spends comes from orders *approaching* halfway. Those are precisely the orders with a first
drink already finished and waiting for its second. Cohesion moves the melted drink from one
customer to another rather than preventing it, and at p90 you are measuring the customer it
moved it to.

§6.4's reasoning is locally sound — for one order in isolation, finishing it faster does
reduce its spread. It does not survive contact with the queue behind it.

**The trigger is the flaw, not the idea.** "Past half made" is not the same quantity as "a
drink has been sitting too long", which is what §9.6 measures and what the melted-first-drink
problem actually is. An order can be 90% made with nothing sitting, or 30% made with a drink
going stale. A boost keyed on `now − first_ready_at` would aim at the real thing and could
reuse the aging machinery, which demonstrably works. Untested — named here so the next
attempt starts from the diagnosis rather than repeating the experiment.

## Consequences

Every §10.4 and §10.5 figure recorded with cohesion on carries its cost; ADR-0013's table is
the affected one, and its DRR row is the `+aging` row rather than the `+aging +cohesion` row
from here on.

`quality_breach_rate` loses the thing it was introduced to validate (§9.6, §10.4's metric
table). It stays useful as a measure of how long drinks sit, but it is no longer evidence for
a scheduler feature — and the run that falsified cohesion is the clearest demonstration that
it was doing its job.

Keeping the knob rather than deleting the branch costs one condition in `quantum_for` and
keeps the finding reproducible from the dashboard by anyone reading this. The scheduler specs
now enable it explicitly, so the mechanism stays covered and a re-triggered version has
somewhere to land.

## Alternatives considered

**Delete cohesion entirely.** Cleanest code. Rejected: the sweep above is only reproducible
while the knob exists, and the idea is worth re-attempting with a corrected trigger. A branch
guarded by a config flag that defaults off is cheap to carry.

**Re-target the trigger to `now − first_ready_at` now.** The likely right answer, and it may
well fail the same way — the barista time still comes from somewhere. Rejected as scope: a
redesign does not belong in the change that stops shipping a harmful default, and it needs its
own sweep to be worth anything.

**Leave it on and document the finding.** Rejected. It costs the catering tail ~24% at ×2.0
and delivers nothing measurable, and leaving a falsified default in place means every later
measurement inherits it.
