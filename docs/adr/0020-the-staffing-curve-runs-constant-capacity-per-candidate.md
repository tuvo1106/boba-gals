# ADR-0020: The staffing curve runs constant capacity per candidate

- **Status:** Accepted
- **Date:** 2026-08-12
- **Design reference:** DESIGN.md §10.4, §10.5 #3

## Context

§10.5 #3 asks for a "staffing curve: for each hour, minimum stations holding p90 under
target. Output is an actual shift schedule." Read literally, that is a request for a
*variable-capacity* simulation — some number of stations open at 10:00, more by the lunch
peak, fewer again in the evening — with the answer being that per-hour number.

`Simulator::World` does not have that lever. `Scenario#stations` is one integer for the
whole simulated day (§10.1), sized once in `World#initialize` and never revisited. Every
other §10.5 experiment sweeps something the simulator already varies per run — the
scheduler config (`Ablation`), the quantum (`QuantumSweep`) — and reruns the day once per
value. Stations is not that kind of knob; building a true variable schedule would mean
`World` accepting a stations-by-hour function and stations coming in and out of
`fill_idle_stations`'s rotation mid-run, which is a change to the simulator core §10.1
calls "the one rule" — it must run the production scheduler unmodified, and a station
count that changes under it is untested territory for `Scheduler.pick_next` in a way a
sweep over existing parameters is not.

That is more than this experiment is worth building today, and CLAUDE.md's standing
direction is breadth over depth in the scheduler's own machinery — see
`breadth-before-scheduler-tuning` — a staffing curve is a dashboard feature, not scheduler
work, but the same instinct against outsized effort for one chart applies.

## Decision

**`Simulator::StaffingCurve` runs the whole day at each of eight candidate station
counts (1–8), buckets each run's completed orders by the hour they arrived, and for
each hour reports the smallest count whose bucket cleared `target_seconds` at p90.**

This answers a related but different question than the literal one: not "what should
hour H be staffed at, given every other hour is staffed to plan", but "if the shop ran
the whole day at N stations, would hour H's customers be fine?" — asked once per N and
read off per hour. It reuses `World` exactly as every other experiment does, at the cost
of not modelling one hour's understaffing spilling a queue into the next.

Every candidate count runs at the same seed + day, the same common-random-numbers
discipline `Ablation` and `QuantumSweep` use (ADR-0011), so a difference between two
counts is the staffing and not a luckier Tuesday. The one place that discipline is
incomplete: more stations means shorter ETA quotes, which means fewer web customers
renege (§10.3) — so a busier hour's bucket can legitimately gain more *completed* orders,
not just faster ones, as the count rises. `arrived` stays identical across counts for the
reason it does across arms and points — it is set in `on_arrival` before the renege
decision — but that number is not currently surfaced per hour, so it is not asserted on in
the spec the way `Ablation`'s and `QuantumSweep`'s `arrived` fields are.

## Alternatives considered

| Option | Why not |
|---|---|
| **True variable-capacity simulation**: give `World` a stations-by-hour schedule and let it flex mid-run | The right long-term answer, and a change to simulator core rather than to a dashboard endpoint. `fill_idle_stations` and `@stations` would need to support stations appearing and disappearing while drinks are in flight — what happens to a drink mid-pour when its station "goes off shift" is an unanswered question the current model has never had to have an opinion on. Revisit if the constant-capacity proxy below is shown to disagree with it materially. |
| **Erlang-C or another closed-form queueing formula per hour** | Faster, and wrong for this shop on its own terms: §10.4 exists because the mean and a closed-form waiting-time formula both hide the heavy-tailed order-size distribution DRR was built for (§1). A method that cannot see a 15-drink order cannot be trusted to size a shift around one. |
| **One simulated day per hour, with only that hour's arrivals** | Removes queue carry-in from the *previous* hour entirely, which is worse than this ADR's proxy, not better — a lunch peak's queue does not start empty at noon in a real shop. |
| **Ship it as a single station count for the whole day** (i.e., not a curve at all) | Answers a different, easier question — §10.5 #3 explicitly asks for a curve because a shop staffs unevenly through the day; a single number throws that away. |

## Consequences

The response is honest about a limit real staffing tools built this way tend to bury:
each hour's number describes a shop staffed at that level *all day*, not a shop that
staffs up for the hour and back down after. Two adjacent hours needing very different
counts (a quiet 10:00 next to a full lunch peak) is not, on its own, evidence that a
literal jump in headcount at the hour boundary would perform the same — a station that
was idle all morning walks into the peak with an empty queue behind it, which this method
cannot represent.

`STATIONS_TRIED` tops out at 8. An hour that still misses `target_seconds` at 8 is
reported as unachieved at the ceiling rather than silently extrapolated past it — the
dashboard should say "we don't know" rather than invent a number nobody measured.

`target_seconds` has no basis in DESIGN.md; `DEFAULT_TARGET_SECONDS` (600) is a dashboard
default, not a store commitment, and is exposed as a request parameter for that reason.

## Revisit when

- The constant-capacity proxy is checked against a true variable-capacity run (built per
  the first alternative above) and found to disagree by more than noise — at that point
  the simpler method should be retired, not kept alongside it.
- A real shift log exists to compare against (§10.5 #5, replay) — that is what would show
  whether the missing carry-in between hours actually matters at this shop's volumes.
