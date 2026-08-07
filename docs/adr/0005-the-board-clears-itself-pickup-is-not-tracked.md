# ADR-0005: The board clears itself on a timer; pickup is not tracked

- **Status:** Accepted
- **Date:** 2026-08-07
- **Design reference:** DESIGN.md §5.1 (order states), §9.1 (surface map), §9.5 (board), §10.3 (generative model), §10.4 (metrics)

## Context

`picked_up` is a terminal order state in §5.1 and `orders.picked_up_at` is in the schema
(§4.1). §9.5 says the board's Ready column persists rows for 90 seconds after
`picked_up_at`.

Nothing in §9.1's surface map sets it. Every listed endpoint stops at `finished`. So the
board needs some rule for retiring a ready row, and one has to be chosen at build step 3.

The obvious candidate is a KDS tap at handoff. Three things argue against it:

**Counter-service shops mostly don't.** Pickup time gets recorded reliably only where the
handoff is already a transaction — drive-thru, delivery couriers confirming in an app,
lockers, a POS that settles at collection. Where you pay up front and wait for your name,
the barista slides the cup onto the shelf and calls out. Bump-at-handoff exists where
there's a dedicated expo person; a three-station shop on a Saturday doesn't have one.

**There is nowhere to tap.** §9.4's KDS is a vertical lane of *drink* cards. Once an
order's drinks are all `finished` they leave that lane, so a ready order has no row on the
kitchen display at all. A tap needs a handoff section that §9.4 does not describe.

**Little depends on it.** The proof that fair queuing works is the §10.5 ablation, which
runs entirely in the simulator, where §10.3 *generates* pickup delay as an exponential
(mean 100s kiosk, 180s web). Live validation of the cohesion boost has a better signal that
needs no pickup at all: §10.4's order cohesion spread, p90 of `ready_at − first_ready_at`,
computed from two timestamps the KDS already writes.

## Decision

**Do not track pickup.** No endpoint, no service, no `picked_up_at` written by the
application. Pickup is a random delay after `ready` — modelled in the simulator per §10.3,
unobserved in the store.

**A ready row is retired 5 minutes after `ready_at`.**

The number comes from the two things that actually constrain it. §10.3 puts mean pickup
delay at 100s (kiosk) and 180s (web), so five minutes is well past when most customers have
walked up. And at §10.3's peak arrival rate of 52 orders/hour, steady-state rows in the
Ready column are arrival rate × time on board:

| Board TTL | Rows at peak |
|---|---|
| 10 min | 8.7 |
| 5 min | 4.3 |

Nine rows is the entire column at 15-foot type, with Making competing for the same screen.

**BoardView still honours the §9.5 90-second rule** for any order that does carry a
`picked_up_at`. It is three lines, it is specified, and it means the read side is already
correct whenever a real pickup signal arrives.

Also rejected:

- **Customer self-service pickup** (public `POST /orders/:pickup_code/pickup`). The pickup
  code is a capability token deliberately sized for low-value reads (§13.1); letting it
  close an order makes an overheard code enough to erase someone else's name from the board
  while they walk toward it.
- **Writing a synthetic `picked_up_at` when the row is retired.** This fabricates a handoff
  that may not have happened, and destroys the distinction between an order someone
  collected and one nobody came back for — which is precisely what `abandoned` (§5.1)
  exists to preserve. The row leaves the board; the state does not change.

## Consequences

**`picked_up` is unreachable in the live application.** Collected and uncollected orders
alike stay `ready` until the 45-minute abandoned sweep. Any future metric measured to
collection has to come from the simulator, or wait for a real pickup signal — a POS that
settles at handoff, or a confirm on the customer's own status page.

**A customer who takes longer than five minutes loses their row.** Accepted: the drink is
on the shelf with their name on it, and their own order status page (§9.2 `OrderChannel`)
still shows it ready. The board is a convenience for the room, not the system of record.

**This does not change §9.1.** No endpoint was added. If pickup tracking is ever built, it
arrives with a KDS handoff section, and that is when `DESIGN.md` gets edited.
