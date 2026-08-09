# ADR-0016: Order broadcasts get the board's throttle, not a publish per transition

- **Status:** Accepted
- **Date:** 2026-08-08
- **Design reference:** DESIGN.md §9.2, §7.2

## Context

§9.2 specifies three channels and throttles exactly one of them: *"Broadcast on every item
state transition and every ETA recompute. Throttle board broadcasts to 1/sec."* Read
literally, `OrderChannel` publishes on every transition, unthrottled.

That reading is fine for the board and the KDS, which are **one stream per store**. It is not
fine for `OrderChannel`, which is **one stream per open order** — and the payload carries
`eta_seconds`, which every transition changes for *every* order, not just the one that moved.
So the fanout multiplies rather than adds:

| | streams per transition |
|---|---|
| `BoardChannel` | 1 |
| `KitchenChannel` | 1 |
| `OrderChannel` | one per open order |

§10.3's peak arrival rate is 52 orders/hour and §7.1's projection covers open orders, so a
busy Saturday holds on the order of 40 open at once. A twenty-transition burst — one large
order being dispatched across four stations — is then **800 publishes** where the board takes
20 and the throttle cuts those to 1.

The trailing flush matters more here than it does for the board. A plain drop loses whichever
transition lands last in a burst; for this view that is the one that says the order is
`ready`, leaving a customer watching "in progress" for a cup already on the counter.

## Decision

`OrderBroadcast` uses the same leading-edge-with-trailing-flush 1-second window as
`BoardBroadcast`, on its own Redis key (`order:throttle:{store_id}`), publishing a snapshot
per open order on each pass. The mechanism moves out of `BoardBroadcast` into a
`ThrottledBroadcast` module both extend.

Both are published from `RecomputeEta.publish`, outside the ETA debounce — the same fix
PR #37 made for the board, for the same reason: two rates, and neither may gate the other.

## Alternatives considered

| Option | Why not |
|---|---|
| Publish per transition, unthrottled, as §9.2 reads | 800 publishes per burst, and it is the one channel where fanout multiplies. |
| Broadcast only the order that actually changed | `eta_seconds` changes for every open order on every transition; this would freeze everyone else's countdown until their own drink moved. |
| Fold order publishes into `BoardBroadcast.publish` | Reuses the window with no new machinery, but hides "also broadcasts every order" inside a class named for the board. |
| Give it a slower window than the board's 1s | A customer's screen and the board above the counter would disagree about the same order, which is the one artefact worth avoiding here. |

## Consequences

A customer's screen and the board move together, because they publish from the same call under
matching windows and read the same `EtaCache` entry.

The cost is that the throttle mechanism is now shared code. `BoardBroadcast` is load-bearing
and its behaviour is asserted by an existing spec file that this change does not touch — those
specs passing unmodified is the evidence the extraction preserved behaviour, and they should
stay that way.

`OrderBroadcast.publish` iterates open orders on every pass. It is one query with
`includes(:order_items)` plus N `PUBLISH` calls, so it is linear in open orders and does not
touch the projection — but it is linear once a second, forever, for as long as the shop is
open.

## Revisit when

Open orders per store sustain above ~150, where the per-pass iteration starts to cost more
than the publishes it damps. At that point the answer is probably to publish only orders whose
serialized view actually changed since the last pass, which needs a per-order digest this
deliberately does not keep.
