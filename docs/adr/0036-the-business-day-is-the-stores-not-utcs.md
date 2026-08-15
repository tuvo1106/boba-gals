# ADR-0036: The business day is the store's, not UTC's

- **Status:** Accepted
- **Date:** 2026-08-14
- **Design reference:** DESIGN.md §13.1, §4.1, §16
- **Relates to:** ADR-0028

## Context

§13.1 makes the pickup code the capability token: four characters from an unambiguous
alphabet, no session, no id — "unique per store **per day**", and the day is what makes a
4-character space workable at all. Both halves of that uniqueness were computed in UTC:

```ruby
scope :for_pickup_code, ->(code, on: Date.current) {
  where(pickup_code: code.to_s.upcase).where("placed_at::date = ?", on)
}
```

`config.time_zone` is commented out in `config/application.rb`, so `Date.current` is a UTC
date; `placed_at::date` is a UTC date; and the unique index `idx_pickup_code_daily` was on
`((placed_at)::date)`, the same UTC definition. Meanwhile `stores.timezone` was validated,
seeded to `America/Los_Angeles`, and **read nowhere in `app/`**.

So the shop's "day" rolled over at 17:00 local — peak service. Reproduced before fixing:

```
Date.current is 2026-08-15 (UTC), store tz is America/Los_Angeles
is K7QF considered taken 7 min later? -> false
Alice polling K7QF now sees: "Bob"
```

An order placed at 16:58 became unfindable by its own pickup code at 17:00 — the customer's
status page 404s and their `OrderChannel` subscription is rejected while their drinks are on
the bar. Worse, `PickupCode.taken?` shared the window, so the live code was considered free
and reissued to the next customer. The first customer's browser, still polling, then rendered
the second customer's first name, drink list and status.

**That is a cross-customer read through the capability token, not a stale page.** It was
reachable once per day, every day, at the busiest hour.

Found by `/code-review high app/controllers app/models app/jobs`.

## Decision

Orders carry a `business_date` column, stamped from `store.timezone`, and both the unique
index and every lookup move onto it.

**A column rather than an expression index**, because the correct expression is
`(placed_at AT TIME ZONE 'UTC' AT TIME ZONE stores.timezone)::date` and a Postgres index
expression cannot reach another table. Hardcoding one zone into the index would work today
and break the first time §16's multi-store lands with a shop in another zone — the exact
assumption that produced this bug.

**Stamped in an `Order` callback, not in `CreateOrder`**, so it holds for every path that
makes an order — factories, the console, a future importer — and cannot drift from
`placed_at`.

**`for_pickup_code`'s `on:` is now required.** It defaulted to `Date.current`, and a default
that silently means "UTC today" is how a caller ends up reading the wrong day without writing
anything that looks wrong. Both callers already have the store in hand.

`Store#business_date(at = Time.current)` is the single definition, and it is the first thing
in the application to read `stores.timezone` at all.

## Consequences

The migration backfills per store — each row's `business_date` is computed from *its own*
store's timezone, not one global assumption — then makes the column `NOT NULL` and swaps the
index. Reversible: `down` restores the expression index and drops the column.

Codes are now correctly scarce for a full shop day rather than resetting mid-service. The
practical effect on the alphabet is the opposite of a relaxation: `PickupCode::ALPHABET` is 29
characters, so 707,281 codes against a day's orders, and `MAX_ATTEMPTS` was never close to
exhaustion. Nothing here pressures that.

Four regression specs pin the boundary: the order stays findable across UTC midnight, its code
stays taken, a code from a genuinely past shop day *is* freed (the property that makes short
codes workable), and `business_date` is stamped from the store's zone rather than the server's.

`config.time_zone` is still unset, deliberately. Setting it would change display formatting
and **would not have fixed this** — `placed_at::date` is evaluated in Postgres against the
stored timestamp, so the SQL day boundary would have stayed UTC regardless. Worth stating
because it looks like the cheap fix and is not one.

## Alternatives considered

| Option | Why not |
|---|---|
| Hardcode the shop's zone in the index expression | Works for one store and bakes a single timezone into the schema. §16 anticipates multi-store; this is the same class of assumption that caused the bug. |
| Set `config.time_zone` globally | Does not fix it. The day boundary lives in a SQL cast against the stored timestamp, not in Rails' zone. It would change formatting and leave the leak intact. |
| Generated/stored column computed in SQL | Needs the store's zone at DDL time, which is the same problem, or a trigger — more machinery and a second place the rule lives. |
| Widen the window instead (free a code after N hours) | Changes what §13.1 specifies rather than implementing it, and a rolling window still lets a code recycle while its order is live. |

## Revisit when

§16's multi-store lands — the per-store backfill and `Store#business_date` already handle it,
but the assumption is worth re-checking against a shop that spans a DST transition mid-shift,
where a "day" is 23 or 25 hours long.
