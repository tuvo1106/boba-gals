# Boba Shop Ordering & Kitchen Scheduling — Design Specification

**Status:** Ready for implementation
**Stack:** Rails 8.x (API + ActionCable), PostgreSQL, React 19 (TypeScript), Redis
**Deploy target:** Docker from day one → Kubernetes (§14)

> **Rails 8 note (locked):** do **not** adopt the Rails 8 "Solid" defaults (Solid Queue/Cable/Cache) or Kamal. Redis is load-bearing in this design — scheduler deficits and ring pointer (§6.5), ETA debounce lock (§7.2), ActionCable pub/sub across pods (§14.4) — so adopting Solid would mean running two coordination stores instead of one. Generate the app with `--skip-solid --skip-kamal`; use the Redis adapter for ActionCable and Sidekiq for jobs (§14.1). Deployment is Kubernetes (§14).
**Audience:** An engineer or coding agent implementing this from scratch
**Jargon:** queueing-theory and networking terms are defined in [§17](#17-glossary)

---

## 1. Problem statement

A boba tea shop needs one system that covers:

1. **Ordering** from an in-store kiosk and from the web (phone/desktop).
2. **Kitchen scheduling** across multiple baristas, where drinks have materially different prep times (40s for a Thai tea, 95s for a brown sugar pearl drink).
3. **A kitchen display (KDS)** where a barista starts and finishes individual drinks.
4. **A customer-facing board** showing what's being made, for whom, and the estimated wait.
5. **A simulation dashboard** to test staffing levels and scheduler parameters before committing to them in the real store.

The central constraint: **a large order must not block small orders.** A customer ordering one drink behind a 15-drink catering order should wait roughly one drink's time, not fifteen.

---

## 2. The core architectural decision

**Schedule drinks, not orders.**

`OrderItem` is the unit of work. `Order` is only a grouping and payment container. Once each drink is independently queueable, "big order blocks small order" reduces to a solved problem — fair queuing, as used in network routers.

Every downstream design choice follows from this. Do not let order-level scheduling creep back in.

---

## 3. Locked decisions

These were decided and are not open for reinterpretation during implementation:

| Area | Decision |
|---|---|
| Kiosk offline | **Refuse orders.** No local queueing, no optimistic accept. Show a clear "can't take orders right now" state. |
| Remakes | Re-queued with **elevated priority** (a priority floor, not a fixed bump — see §6.4). |
| Board privacy | **First name + pickup code only.** Never full names. |
| Quality timer | **Included.** Tracks how long a finished drink sits before pickup; flags breaches. |
| Simulation | **Part of the app**, as a React dashboard, running the real scheduler code. |

---

## 4. Domain model

### 4.1 Schema

```ruby
# stores
t.string  :name, null: false
t.string  :timezone, null: false, default: "America/Los_Angeles"
t.integer :station_count, null: false, default: 3    # store-setup seed only; runtime truth is stations WHERE active
t.jsonb   :scheduler_config, null: false, default: {}   # see §6.6
t.boolean :accepting_orders, null: false, default: true

# menu_items
t.references :store, null: false
t.string  :name, null: false
t.string  :category                       # milk_tea, fruit_tea, slush, specialty
t.integer :base_prep_seconds, null: false
t.integer :price_cents, null: false
t.boolean :available, null: false, default: true
t.integer :position                       # display order

# option_groups   (Sweetness, Ice, Toppings, Size)
t.references :menu_item, null: false
t.string  :name, null: false
t.integer :min_select, default: 0
t.integer :max_select, default: 1

# options         (50% sugar, Extra pearls, Large)
t.references :option_group, null: false
t.string  :name, null: false
t.integer :price_cents, default: 0
t.integer :prep_seconds_delta, default: 0   # extra pearls => +15, etc.

# orders
t.references :store, null: false
t.string  :source, null: false             # "kiosk" | "web"
t.string  :pickup_code, null: false        # 4 chars, e.g. "K7QF" — unique per store per day
t.string  :customer_first_name             # displayed on board
t.string  :customer_phone                  # web only, for SMS; never displayed
t.string  :status, null: false             # see §5.1
t.datetime :placed_at
t.datetime :promised_at                    # order-ahead target; nil = ASAP
t.datetime :first_ready_at
t.datetime :ready_at
t.datetime :picked_up_at
t.integer :quoted_wait_seconds             # ETA shown at order time; used for ETA-error metrics
t.integer :total_cents

# order_items
t.references :order, null: false
t.references :menu_item, null: false
t.jsonb   :selected_options, default: []   # denormalized snapshot: [{option_id, name, prep_seconds_delta}]
t.string  :label                           # denormalized display string, e.g. "Brown Sugar Pearl, 50%, less ice"
t.integer :prep_seconds, null: false       # base + sum(option deltas), frozen at creation
t.string  :status, null: false             # see §5.2
t.references :station, null: true
t.references :barista, null: true
t.datetime :queued_at
t.datetime :started_at
t.datetime :finished_at
t.references :remake_of, null: true, foreign_key: { to_table: :order_items }
t.string  :remake_reason
t.integer :sequence                        # position within its order, for display

# stations
t.references :store, null: false
t.string  :name                            # "Bar 1", "Blender"
t.boolean :active, default: true

# baristas
t.references :store, null: false
t.string  :name
t.string  :pin_digest                      # KDS login (bcrypt, see §13.3)

# admin_users     (dashboard/config auth, see §13.4 — created via seed, no signup)
t.string  :email, null: false             # unique index
t.string  :password_digest, null: false

# prep_time_stats   (EWMA of observed durations)
t.references :menu_item, null: false
t.float   :ewma_seconds
t.float   :ewma_variance
t.integer :sample_count
t.datetime :updated_at

# scheduler_events  (append-only audit + simulator replay source)
t.references :store, null: false
t.string  :event_type          # order_placed, item_queued, item_started, item_finished,
                               # item_remade, order_ready, order_picked_up, quality_breach
t.references :order_item, null: true
t.jsonb   :payload
t.datetime :occurred_at
```

### 4.2 Indexes that matter

```sql
CREATE INDEX idx_items_dispatchable
  ON order_items (status, queued_at)
  WHERE status = 'queued';

CREATE INDEX idx_items_active
  ON order_items (station_id, status)
  WHERE status IN ('queued', 'in_progress');

CREATE INDEX idx_orders_open
  ON orders (store_id, status)
  WHERE status NOT IN ('picked_up', 'cancelled');

CREATE UNIQUE INDEX idx_pickup_code_daily
  ON orders (store_id, pickup_code, (placed_at::date));
```

Note: `placed_at::date` buckets by UTC day, not store-local day — acceptable for a single-timezone deployment. If it ever matters, add a `business_date` column set at placement in store time.

---

## 5. State machines

### 5.1 Order

```
draft ──> placed ──> in_progress ──> partially_ready ──> ready ──> picked_up
             │            │                 │              │
             │            │                 │              ├──> abandoned
             └────────────┴─────────────────┴──────────────┴──> cancelled
```

- `partially_ready` — at least one drink done, not all. Drives the cohesion boost (§6.4) and the quality timer.
- `ready` — all items `finished`.
- `abandoned` — swept by a recurring background job (runs every 5 min) if not picked up 45 min after `ready_at`. Terminal, like `picked_up`; excluded from the "open orders" index and the board.

### 5.2 OrderItem

```
queued ──> in_progress ──> finished
   │            │              │
   │            └──> failed ───┘ (creates a new queued item, remake_of = self)
   └──> cancelled
```

Rule: `finished` is terminal. A failed drink is never "un-finished" — a new `OrderItem` row is created. This keeps prep-time statistics honest and makes remakes visible in reporting.

**One exception:** the KDS undo (§9.1) may revert `finished → in_progress` (and `in_progress → queued`) within its 60-second window. Undo corrects a mistap, not a drink — the implementation must also discard the prep-time sample so the EWMA (§7.3) doesn't learn from phantom durations, and re-run the order-status rollup (an undone finish can move an order from `ready` back to `partially_ready`). A drink that was genuinely made and is wrong is a remake, never an undo.

---

## 6. The scheduler

### 6.1 Algorithm: Deficit Round Robin over orders

Deficit Round Robin comes from network routers (Shreedhar & Varghese, 1995), where it shares bandwidth between connections sending different-sized packets. The mapping onto a boba shop is direct:

| Networking | Here |
|---|---|
| Flow | An **order** |
| Packet | A **drink** |
| Packet size | `prep_seconds` |
| Bandwidth | Barista time |

#### Why plain round robin is not enough

Give every order one turn per round and you have shared *turns*, not shared *time*.

Sarah orders five Thai teas (40 prep-seconds each). Mike orders five brown sugar pearl drinks (95 each). Strict alternation looks scrupulously fair:

| Round | Served | Sarah's barista time | Mike's barista time |
|---|---|---|---|
| 1 | Sarah, Mike | 40s | 95s |
| 2 | Sarah, Mike | 80s | 190s |
| 3 | Sarah, Mike | 120s | 285s |
| 4 | Sarah, Mike | 160s | 380s |
| 5 | Sarah, Mike | 200s | **475s** |

Mike consumed **2.4× the shop's capacity** while receiving exactly the same number of turns. Nobody did anything wrong; the unit of accounting is simply incorrect. Fair queuing has to allocate *work*, and a turn is not a unit of work.

#### The deficit

Each flow carries a counter measured in prep-seconds, and one rule governs it:

```
per round:   deficit += quantum
serve while: deficit >= head.prep_seconds   →   deficit -= head.prep_seconds
```

**Unspent credit carries to the next round.** That single property is what the algorithm is named for, and dropping it breaks everything: with a 60-second quantum and a 95-second drink, a flow that reset each round could never afford its head and would starve permanently. Carrying means it holds 60, then 120, and serves on the second round.

Run Sarah and Mike through it with `Q = 120`. Sarah's drinks cost 40, Mike's cost 95:

| Round | Sarah: deficit → served | Mike: deficit → served |
|---|---|---|
| 1 | 0+120 → **3 drinks**, 0 left | 0+120 → **1 drink**, 25 left |
| 2 | 0+120 → **3 drinks**, 0 left | 25+120=145 → **1 drink**, 50 left |
| 3 | 0+120 → **3 drinks**, 0 left | 50+120=170 → **1 drink**, 75 left |
| 4 | 0+120 → **3 drinks**, 0 left | 75+120=195 → **2 drinks**, 5 left |

After four rounds Sarah has received **480 seconds** of barista time and Mike **475** — from wildly different drink counts (12 versus 5). The carried remainder is doing the work: Mike's leftovers accumulate across rounds until they buy him an extra drink in round 4, which is exactly where the discrepancy gets repaid.

Compare that to the plain round-robin table above, where the same two customers ended 200 against 475.

#### The guarantee

Over `r` rounds a flow receives at least `r × Q − max_drink` seconds of service and at most `r × Q`. The error never accumulates, because whatever a round underspends is exactly what carries into the next one. So:

```
service_i(r)  =  r × Q  ±  max_drink
```

Two flows with equal quanta therefore differ by at most one drink's worth of work, *no matter how differently sized their drinks are*, and the relative error shrinks as `r` grows. In the trace above the gap after four rounds is 5 seconds against a 480-second allocation — about 1%.

That is the sense in which DRR is fair, and it is a stronger statement than "everyone gets a turn".

#### Choosing the quantum

**Quantum default: 60 prep-seconds** — about one drink per round.

The constraint the literature cares about is `Q ≥ max_item`. When it holds, every visit to a flow serves at least one item and the work per dispatch is O(1) amortised. That is why DRR exists at all: weighted fair queuing achieves comparable fairness but needs virtual-time bookkeeping and a priority queue, at O(log n) per packet. DRR trades a bounded fairness error for a counter and an array.

**On the seeded menu, that constraint does not hold, and the default deliberately does not try to make it hold.** The most expensive drink is a Brown Sugar Pearl at 95 seconds with three toppings — boba pearls +15, extra pearls +15, grass jelly +10 — for **135**.

Nothing breaks, because the deficit carries:

| Visit | Deficit | Can it afford 135? |
|---|---|---|
| 1 | 0 + 60 = 60 | No — yield, carry 60 |
| 2 | 60 + 60 = 120 | No — yield, carry 120 |
| 3 | 120 + 60 = 180 | **Yes** — serve, 45 left |

The priciest drink in the shop waits two extra ring traversals, and the amortised bound weakens from O(1) to O(⌈max_item / Q⌉) — here, three. Ring traversal is an array walk over open orders; §10.5 measures the throughput cost of paying it more often as nil (see below).

**Raise the quantum** and each order is served in longer uninterrupted stretches — better for cohesion, worse for the small order waiting behind. **Lower it** and interleaving is finer, down to the point where a quantum smaller than the cheapest drink buys nothing, because drinks are atomic and cannot be split.

#### What the sweep found (§10.5)

The default was 120 until this was measured. §10.5's sweep, 24 seeds × 11-hour day, 3 stations, 1.5× demand, `n = 11,271` small orders:

| `Q` | small orders overtaken | p90 delay when overtaken | p99 | 1–2 drink p90 **wait** |
|---|---|---|---|---|
| 45 | 13.1% | 88s | 247s | 272s |
| **60** | **11.4%** | **88s** | **262s** | **281s** |
| 75 | 8.8% | 125s | 393s | 271s |
| 90 | 5.8% | 217s | 492s | 257s |
| 120 | 3.5% | 250s | 793s | 268s |
| 135 | 2.5% | 383s | 1022s | 281s |

Three results, none of which were obvious in advance:

**The quantum does not change how long anyone waits.** The wait column spans 257–281s with no monotone trend across a 3× range of `Q`, and station utilisation is identical to three decimal places. It is the same work either way. Everything the quantum controls is *distribution*, not throughput — which also means the O(⌈max_item / Q⌉) traversal cost above is free in practice.

**What it does control is whether delay is spread or concentrated.** A small `Q` rotates the ring fast, so many customers are overtaken slightly. A large `Q` lets one order run uninterrupted, so few are overtaken but those who are lose minutes. At `Q = 135` the p99 is over seventeen minutes.

**`Q = 60` is the knee.** p90 delay is 88s at both 45 and 60 and then climbs steadily; going below 60 buys nothing. The mechanism is that the cheapest drinks are 40 and 45 seconds, so 60 is already about one drink per turn — the finest interleaving that exists, because a drink cannot be split.

Concentrated delay is the worse failure. A customer whose estimate moves by 88 seconds does not notice; one whose estimate jumps four minutes reads it as a broken promise, and §7.3 is explicit that a wait people stop believing is worse than a longer one. The default therefore optimises for the *shape* of the delay, since it cannot change the amount.

**Not measured, and the one real argument against:** the simulator has no model of a barista switching between drink types. A finer quantum interleaves more, and if switching has a real cost in a real kitchen — different cups, different toppings, a blender that has to be rinsed — then `Q = 60` buys its smoothness with throughput the simulator cannot see. Revisit against a real shift before trusting it past the simulator.

#### What this design adds

Textbook DRR is unweighted and walks flows in arrival order. This design scales each flow's quantum by three factors and reorders the ring. The deficit accounting underneath is unchanged, which is what preserves the guarantee above.

**Aging** (§6.2) — a flow's quantum grows by `aging_rate` (0.15) per minute waited. This is the anti-starvation guarantee, and it is needed because "an equal share of every round" still means "never finishes" when rounds keep gaining new flows.

> A 12-drink order arrives at 12:00. From 12:01 a new single-drink order arrives every 30 seconds. By 12:20 there are 39 other flows, and an unweighted ring would give the catering order 1/40th of the shop. With aging its multiplier is `1 + 0.15 × 20 = 4.0` against the newcomers' ~1.0, so it draws four times their quantum and finishes.

**Cohesion** (§6.2, §6.4) — a flow more than half made gets `+cohesion_boost` to its multiplier, so the rest of that order is finished rather than interleaved away. It exists for the **melted first drink**, and measurement says it does not achieve that: it ships disabled (ADR-0014).

> A four-drink order. Perfect interleaving serves drinks 1 and 2, then the order waits its turn behind everyone else for drinks 3 and 4. Drink 1 was finished at minute 1 and is still on the counter at minute 7 — ice melted, foam collapsed, past `quality_limit_seconds` (300). The customer receives one good drink and one that has been sitting for six minutes.
>
> Once 2 of 4 are made, cohesion doubles the quantum from 60 to 120, so the remaining two drinks come out in a single visit rather than two. Perfect interleaving is fair to *orders* and unkind to *drinks*, because a finished drink degrades while it waits. Cohesion is the deliberate unfairness that fixes it, and §9.6's quality timer measures whether it worked.

**Measured, it does not work — it is off by default (ADR-0014).** Sweeping `cohesion_boost` from 0 to 4.0 over 20 seeds makes `cohesion_spread` — this section's own metric — monotonically *worse* at every load above idle, in every order-size class, including the four-drink case above:

| order size | ×2.0 off → on | ×2.6 off → on |
|---|---|---|
| 2 | 113s → 126s | 104s → 120s |
| 3–6 | 943s → 988s | 1576s → 2001s |
| 7+ | 3159s → 3458s | 6715s → 7505s |

The argument above is locally sound and globally wrong. The boost accelerates orders *past* halfway using barista time taken from orders *approaching* halfway — and those are exactly the orders with a first drink already sitting. It moves the melted drink rather than preventing it. The trigger is the flaw: "past half made" is not the same quantity as "a drink has been sitting too long", which is what §9.6 actually measures. A boost keyed on `now - first_ready_at` is the untested alternative.

**Remake floor** (§6.4) — a flow with a pending remake sorts into a strictly higher tier.

> A drink is dropped at 12:30 and re-queued. An ordinary order placed at 12:00 has been aging for 30 minutes: multiplier `1 + 0.15 × 30 = 5.5`. The fresh remake, as an additive bump, is `1 + 4.0 = 5.0` — and **loses**. The customer whose drink was dropped waits behind someone whose only distinction is having ordered earlier. A tier means the remake sorts first regardless of age, while `-quantum` *within* the tier keeps two remakes competing by age.

**Priority-ordered ring** (ADR-0009) — flows are visited in descending quantum rather than arrival order.

> Two orders placed in the same second, one carrying a remake. Walked in arrival order, the ring asks index 0 first — and the ordinary order is served first no matter how large the remake's quantum is. Measured on the unmodified pseudocode, the remake got 5× the throughput per round and still went second. A multiplier decides *how much* service a flow gets, never *who is asked first*; without reordering, all three boosts above are invisible as ordering.

The result: a solo customer behind a 12-drink order waits roughly one quantum, while the large order still progresses steadily rather than being starved.

### 6.2 Pseudocode

This is the reference implementation. It must be a **pure function** — no ActiveRecord, no `Time.now`, no I/O — so the simulator can run it unmodified (§10.1).

```ruby
# state: { flows: [Flow], pointer: Integer, config: Config }
# Flow: { id, arrived_at, deficit, queue: [Item], made_count, total_items,
#         has_pending_remake, promised_at }
# Item: { id, prep_seconds, enqueued_at, is_remake }
#
# Returns the next {flow:, item:} to dispatch, or nil if nothing is dispatchable.

def pick_next(state, now)
  return pick_fifo(state) if state.config.policy == :fifo

  live = state.flows.select { |f| f.queue.any? && eligible?(f, now, state.config) }
  return nil if live.empty?

  guard = 0
  loop do
    guard += 1
    raise "scheduler livelock" if guard > 10_000

    # Priority order, not arrival order (ADR-0009). A quantum multiplier decides
    # how much service a flow gets per round; it cannot decide who is asked
    # first. Walking in arrival order makes §6.4's "remakes outrank same-age
    # normal work" untrue no matter how large the multiplier.
    ring = priority_ring(state, now)
    state.pointer = 0 if state.pointer >= ring.size
    flow = ring[state.pointer]

    if flow.queue.empty? || !eligible?(flow, now, state.config)
      state.advance!            # advance the pointer AND end this flow's visit
      next
    end

    # One quantum per flow per round — the definition of the algorithm. Without
    # tracking the grant, a flow whose quantum covers its next drink dispatches,
    # keeps the pointer, and tops itself up again indefinitely: at the default
    # 120s quantum against 60s drinks the first order drains completely before
    # any other is touched.
    unless state.granted?(flow)
      flow.deficit += quantum_for(flow, now, state.config)
      state.grant!(flow)
    end

    head = flow.queue.first

    if flow.deficit >= head.prep_seconds
      flow.deficit -= head.prep_seconds
      return { flow: flow, item: flow.queue.shift }
    end

    state.advance!              # this visit's quantum is spent; remainder carries
  end
end

# The order flows are visited in. Fairness is unaffected — it lives in the
# deficit accounting, and every flow still draws one quantum per round.
def priority_ring(state, now)
  state.flows.each_with_index.sort_by do |flow, index|
    [ flow.has_pending_remake ? 0 : 1,        # the floor (§6.4) — a tier, not a number
      -quantum_for(flow, now, state.config),  # aging and cohesion
      index ]                                 # stable, so ties are deterministic
  end.map(&:first)
end

def quantum_for(flow, now, config)
  multiplier = 1.0

  # Aging: nothing starves, even under a continuous stream of small orders.
  if config.aging_enabled
    waited_minutes = (now - flow.arrived_at) / 60.0
    multiplier += config.aging_rate * waited_minutes      # default 0.15 per minute
  end

  # Cohesion: once an order is half made, finish it rather than let the
  # first drinks sit and melt.
  if config.cohesion_enabled && flow.total_items > 1 &&
     flow.made_count.to_f / flow.total_items >= 0.5
    multiplier += config.cohesion_boost                   # 1.0, but disabled by default (ADR-0014)
  end

  # Remake: extra throughput once its turn comes. The *ordering* guarantee lives
  # in priority_ring — a number added here is a rate, not a rank (§6.4).
  multiplier += config.remake_multiplier if flow.has_pending_remake   # default 4.0

  config.quantum * multiplier
end

# Backward scheduling for order-ahead: don't make an 11am pickup at 9am.
def eligible?(flow, now, config)
  return true if flow.promised_at.nil?
  remaining = flow.queue.sum(&:prep_seconds)
  target_start = flow.promised_at - remaining - config.promise_buffer  # default 120s
  now >= target_start
end
```

### 6.3 Comparison arms

Keep `policy: :fifo` implemented permanently — strict `ORDER BY queued_at, id`. It is the control arm for the simulator's ablation study (§10.5) and the fallback if DRR misbehaves in production.

Two further arms exist **for the simulator only**, because FIFO alone cannot separate the two claims this design actually makes:

| Arm | Rule | What it isolates |
|---|---|---|
| `rr` | one drink per order per turn, ignoring `prep_seconds` | **What the deficit is for.** DRR is round robin plus the deficit; RR is the same ring without it. FIFO shows you need fairness, RR shows you need *this* fairness — that serving turns equally is not the same as serving time equally when the menu spans 40s to 135s (§1). |
| `sjf` | always the shortest queued drink | **The price of fairness.** Shortest-job-first minimises mean wait and is the bound DRR is paying against. It starves whatever is expensive, which is exactly the failure §1 exists to prevent — so it is a benchmark, never a policy. |

**What SJF starves is the expensive *drink*, not the large *order*.** This section originally said "large orders by construction", which assumes drink cost tracks order size. It does not: §2 makes the scheduled unit a drink, and §10.3 draws each drink's cost independently of how many drinks the order has, so a 15-drink catering order has fifteen chances to hold a cheap one and SJF serves it happily. Measured (ADR-0013, reproduced by §10.5's ablation), SJF's 7+ order p90 *beats* DRR's, while its dear/cheap p90 ratio reaches 38× at 2.2× demand against DRR's 2.0×.

The conclusion is unchanged and the reason is narrower: SJF is unshippable because a customer's wait must not depend on what they ordered (§6.1), not because catering orders are its victim. Two things follow. Judging SJF on §10.4's size classes alone makes it look like the best arm on the chart, so §10.5's ablation must show the drink-cost split beside the size split. And a menu whose catering orders skewed toward the 95s items would make the original claim true after all — the two failures coincide only when the menu makes them coincide.

`rr` and `sjf` are not selectable on a store. `UpdateSchedulerConfig` (§6.6) accepts `drr` and `fifo` only. A policy that provably starves part of the menu must not be one dropdown away from production, and a policy whose whole purpose is to make an argument in a chart has no business dispatching real drinks.

### 6.4 Why a priority *floor* for remakes

A fixed additive bump gets swamped in a busy queue: after 20 minutes of aging, a normal order's multiplier exceeds a fresh remake's.

**So the floor is a tier, not a number** (ADR-0009). `priority_ring` sorts flows with a pending remake ahead of every flow without one, and orders *within* each tier by quantum — which preserves the other half of the requirement: two remakes still compete with each other by age, so the customer whose drink was dropped ten minutes ago beats the one whose drink was dropped one minute ago.

A large multiplier is not sufficient, and cannot be made sufficient. Any number added to a multiplier is exceeded by a competitor aged long enough — `remake_multiplier: 4.0` against `aging_rate: 0.15` is overtaken at roughly 27 minutes, which is the same failure this section opens by describing. The multiplier still earns its place: it is what lets a remade order *clear* faster once its turn arrives, rather than merely starting sooner.

### 6.5 Do not materialize a queue table

At boba-shop volume (hundreds of orders/day, low thousands of drinks) the flow set fits in memory. Rebuild scheduler state from `order_items WHERE status = 'queued'` on each dispatch cycle, ordered by `queued_at`. Persist `deficit` per open order in Redis (`sched:{store_id}:deficit:{order_id}`, TTL 6h) so it survives a process restart; if Redis is cold, deficits reset to zero, which is safe — it just means one round of unfairness. Persist the ring pointer the same way (`sched:{store_id}:pointer`), stored as the order id it points at — an array index is meaningless across rebuilds; on load, resume at the first flow whose id is ≥ the stored id (the flow array is ordered by `arrived_at`, so use the stored flow's position, falling back to 0 if that order is gone). A lost pointer is as harmless as a lost deficit.

Reconsider this only above ~50 orders/hour sustained.

### 6.6 Configuration (`stores.scheduler_config`)

```json
{
  "policy": "drr",
  "quantum": 60,
  "aging_enabled": true,
  "aging_rate": 0.15,
  "cohesion_enabled": false,
  "cohesion_boost": 1.0,
  "remake_multiplier": 4.0,
  "promise_buffer": 120,
  "quality_limit_seconds": 300,
  "eta_safety_factor": 1.15
}
```

Editable from the simulation dashboard, with an explicit "apply to store" action so tuning never silently changes live behavior.

---

## 7. ETA projection

### 7.1 Method

Run the same scheduler forward as a simulation against the current queue. Assign queued items to the next-free station; the projection yields `projected_start_at` and `projected_ready_at` per item. **Order ETA = max over its items**, multiplied by `eta_safety_factor`.

This is the only method that stays correct as scheduler parameters change — a formula like `total_work / stations` will drift the moment you touch the quantum.

### 7.2 Recompute triggers

- Order placed
- Item started / finished
- Remake created
- Station activated or deactivated
- Idle tick every 30s (catches drift from slow drinks in progress)

Run in a background job (Sidekiq — see §14.1), debounced to at most one run per store per 2 seconds. The debounce must be a Redis lock (`SET eta_lock:{store_id} 1 NX PX 2000`), not in-process state — web pods come in pairs (§14.4). Broadcast the result over ActionCable.

### 7.3 Learned prep times

Seeded `base_prep_seconds` will be wrong. Maintain an EWMA per menu item from observed `finished_at - started_at`:

```ruby
ALPHA = 0.2
new_ewma = ALPHA * observed + (1 - ALPHA) * old_ewma
```

Discard samples outside `[0.25x, 4x]` of current EWMA — those are a barista who forgot to tap "finish", not a slow drink. Require `sample_count >= 10` before the EWMA overrides the seeded value.

**This is the difference between a board customers trust and one they learn to ignore.** Track ETA error and bias as first-class metrics (§10.4).

---

## 8. Concurrency

Two baristas will tap "start" on the same drink. Claim with row-level locking so the second tap silently gets the *next* drink instead of an error dialog:

```ruby
class ClaimNextDrink
  def call(station:, barista:)
    OrderItem.transaction do
      candidates = OrderItem
        .joins(:order)
        .where(orders: { store_id: station.store_id })
        .where(status: "queued")
        .order(:queued_at)
        .limit(50)
        .lock("FOR UPDATE SKIP LOCKED")

      pick = Scheduler.pick_next(Scheduler::State.from(candidates), Time.current)
      return nil if pick.nil?

      item = OrderItem.find(pick[:item].id)
      item.update!(status: "in_progress", station: station,
                   barista: barista, started_at: Time.current)
      item
    end
  end
end
```

`SKIP LOCKED` removes most of the race conditions you would otherwise chase. Keep the transaction short — no broadcasts inside it; enqueue those after commit via `after_commit`.

---

## 9. Applications

### 9.1 Shared API surface

```
# Ordering (kiosk + web)
GET    /api/v1/menu                         -> items, option groups, availability
POST   /api/v1/orders                       -> { order, pickup_code, quoted_wait_seconds }
GET    /api/v1/orders/:pickup_code          -> status + ETA (public, code acts as the token)
GET    /api/v1/health                       -> kiosk connectivity probe

# Kitchen display
POST   /api/v1/kds/session                  -> barista PIN login, returns station token
GET    /api/v1/kds/queue                    -> in-progress + next-up, scheduler-ordered
POST   /api/v1/kds/items/:id/start
POST   /api/v1/kds/items/:id/finish
POST   /api/v1/kds/items/:id/fail           -> { reason } creates remake
POST   /api/v1/kds/items/:id/undo           -> reverts last transition, 60s window

# Board
GET    /api/v1/board                        -> in-progress + ready, first names + codes

# Admin / simulation
GET    /api/v1/admin/scheduler_config
PATCH  /api/v1/admin/scheduler_config
POST   /api/v1/admin/simulations            -> run scenario server-side, return metrics
GET    /api/v1/admin/prep_time_stats
```

### 9.2 ActionCable channels

All store-scoped. Payloads are complete snapshots of a bounded view, not deltas — the views are small and idempotent replacement removes an entire class of sync bug.

```js
// KitchenChannel — { store_id }
{ type: "queue_update", in_progress: [...], next_up: [...], depth: 14 }

// BoardChannel — { store_id }
{ type: "board_update",
  making: [{ first_name, pickup_code, items: ["Taro Slush"], eta_seconds: 240 }],
  ready:  [{ first_name, pickup_code, ready_since_seconds: 45 }] }

// OrderChannel — { pickup_code }
{ type: "order_update", status: "in_progress", eta_seconds: 180,
  items: [{ label, status }] }
```

Broadcast on every item state transition and every ETA recompute. Throttle board broadcasts to 1/sec.

### 9.3 Ordering app (kiosk + web)

One React codebase, one build. Kiosk mode is a runtime flag, not a fork.

| | Kiosk | Web |
|---|---|---|
| Idle reset | 90s inactivity → clear cart, return to attract screen | none |
| Auth | none | guest-only in v1 (accounts deferred — there is deliberately no `users` table in §4.1) |
| Hit targets | min 64px | min 44px |
| Name entry | first name, on-screen keyboard | first name + phone for SMS |
| Payment | pay at counter (terminal integration deferred) | pay at counter (Stripe deferred) |
| Order-ahead | no | yes, `promised_at` |

**Payment, v1 (locked for solo scope):** record `total_cents`, settle at the register. Terminal and Stripe integrations are integration work, not design work — they sit behind a `PaymentProvider` port (`authorize(order) -> Result`, with a `CounterPayment` implementation that always succeeds) and come after the scheduler is proven. Nothing in the scheduler depends on payment state, which also defers the payment-failure open question (§16).

**Offline behavior (locked):** the kiosk polls `/api/v1/health` every 10s. Two consecutive failures → full-screen state:

> **Ordering is paused**
> The kiosk can't reach the store system. Please order at the counter.

No local queue, no optimistic accept. The cart is preserved in memory so a brief blip doesn't lose an in-progress order, but the "Place order" action stays disabled until health recovers. Rationale: a queued order that fails to sync produces a customer holding a receipt for a drink the kitchen never saw — strictly worse than a clear refusal.

### 9.4 Kitchen display (KDS)

Layout: a single vertical lane of drink cards, largest at top.

Each card shows: drink name, options (sweetness/ice/toppings as bold short tokens — `50%`, `LESS ICE`, `+PEARL`), pickup code, and position within its order (`2 of 5`). Remakes carry a distinct persistent marker.

Interaction rules:

- One tap to start, one tap to finish. **No confirmation dialogs.**
- Undo is the escape hatch: a 60-second undo affordance on the last action.
- Always render a **Next up** section (3 items) so a barista can pre-stage cups and toppings. This is where real throughput comes from.
- Fail/remake requires a reason tap (spill, wrong order, quality) — one screen, four large buttons.
- Show queue depth and the oldest waiting time in the header. Nothing else.

### 9.5 Customer board

Two columns, high contrast, readable at 15 feet.

- **Making** — first name, pickup code, ETA in minutes (never seconds; false precision reads as a lie). Show `Almost ready` under 2 minutes.
- **Ready** — first name, pickup code, visually dominant. Items persist for 90 seconds after `picked_up_at` so a customer walking up doesn't see their name vanish.

Privacy (locked): first name plus code only. If two `Sarah`s are active, disambiguate by code, never by adding a surname initial.

Quality timer surfaces here only as a subtle staff-visible marker on rows past `quality_limit_seconds`; customers never see "your drink is going stale."

### 9.6 Quality timer

Starts when a drink reaches `finished`. Measures `now - finished_at` until `picked_up_at`.

- Per-drink breach when sitting time exceeds `quality_limit_seconds` (default 300).
- Logged to `scheduler_events` as `quality_breach`.
- On the KDS, a breached order shows a marker prompting a check-in or a proactive remake.
- Multi-drink orders are the main source: the first drink sits while the last is made. This is what the cohesion boost (§6.4) was meant to reduce; measured, it does not, and the breach rate is how that was established (ADR-0014).

### 9.7 SMS notification (web orders only)

Exactly one message, sent when the order transitions to `ready`:

> Your Boba Gals order {PICKUP_CODE} is ready for pickup!

- Sent via a `NotificationSender` port: `TwilioSender` in production, `LogSender` in dev/test/simulation. Enqueued from the same `after_commit` that broadcasts `order_ready` — never inside the transaction.
- No "we've started your order" chatter; `OrderChannel` already covers live status.
- No retry beyond Sidekiq's default; a lost SMS is a shrug, not an incident. Never block or fail an order transition on SMS failure.
- Deferred to build step 8 (§12); `customer_phone` is collected from day one but unused until then.

---

## 10. Simulation dashboard

### 10.1 The one rule

**The simulator must run the production scheduler, not a reimplementation of it.** Otherwise you are tuning a model of your system rather than your system.

Therefore `pick_next` (§6.2) is written as a pure function from the start, with three injected dependencies:

| Dependency | Production | Simulation |
|---|---|---|
| `Clock` | `RealClock` (`Time.current`) | `SimClock` (event-driven, jumps) |
| `Repository` | ActiveRecord-backed | in-memory arrays |
| `PrepTimeModel` | EWMA from `prep_time_stats` | sampled distribution |

Two viable implementations, pick one:

- **(A) Server-side** — scheduler and simulator both in Ruby; the dashboard posts a scenario to `POST /api/v1/admin/simulations` and renders returned metrics. Guarantees one implementation. **Recommended.**
- **(B) Client-side** — scheduler core compiled to WASM or ported to TS with a shared golden-test suite asserting identical dispatch sequences on fixed seeds. Faster interaction, more maintenance.

If (B), the golden tests are not optional: 20 fixed scenarios, assert the exact dispatch order matches Ruby.

### 10.2 Discrete-event loop

Not tick-based. Maintain a priority queue of events and jump the clock to the next one:

```
ORDER_ARRIVES · DRINK_STARTED · DRINK_FINISHED · DRINK_FAILED · ORDER_READY · PICKUP
```

A 12-hour simulated day completes in well under a second, which is what makes parameter sweeps (thousands of runs) practical instead of eyeballing three configurations.

**Seed the RNG and surface the seed in the UI.** Reproducible bad days are the entire point.

### 10.3 Generative model

| Process | Distribution | Default |
|---|---|---|
| Arrivals | Non-homogeneous Poisson via thinning | λ(t) profile below |
| Order size | Mixture, heavy-tailed | 62% 1 drink, 22% 2, 9% 3, 4% 4–6, 3% 8–20 |
| Item choice | Weighted categorical over menu | popularity weights |
| Prep time | Lognormal around item mean | σ = 0.28 |
| Barista skill | Per-worker multiplier, drawn once | U(0.85, 1.20) |
| Fatigue | Multiplier when queue depth > 12 | ×1.08 |
| Pickup delay | Exponential | mean 100s kiosk, 180s web |
| Remake rate | Bernoulli per drink | 2% |
| Reneging (web) | `p = clamp((eta − 480) / 1200, 0, 0.8)` | — |

λ(t), orders/hour, 10:00–21:00: `12, 22, 48, 40, 26, 38, 52, 44, 36, 42, 24`

#### What each distribution is, and why that shape

Every choice here is load-bearing. Flattening any of them makes the simulator agree with
whatever you already believed. Terms are defined in §17.

**Non-homogeneous Poisson arrivals, by thinning.** A Poisson process is "events happen
independently at some average rate" — the standard model for customers walking in, because
one person's arrival tells you nothing about the next. *Non-homogeneous* means the rate
changes through the day. *Thinning* is how you sample it: generate arrivals at the busiest
rate (52/hour), then keep each one with probability `rate_now / peak`. At 10am, where the rate
is 12/hour, you keep about 23% and discard the rest.

> **Flat arrivals will make everything look fine.** A uniform rate keeps the shop below
> saturation all day, and below saturation every scheduler looks identical. The peaks are the
> entire test.

**Heavy-tailed order sizes.** "Heavy-tailed" means rare-but-large values are common enough to
matter. 62% of orders are a single drink, but 3% are 8–20 — and that 3% carries about a
quarter of the shop's total work.

> **Order size must be heavy-tailed.** A tidier distribution — Poisson or geometric — would
> almost never generate the 15-drink catering order, and the catering order is the entire
> reason DRR exists.

**Lognormal prep times, σ = 0.28.** A lognormal is a bell curve applied to the *logarithm* of
the value, which makes it asymmetric: a floor at zero, and a long tail on the slow side. For a
45-second drink at σ = 0.28, roughly two thirds land between 34 and 60 seconds, but a small
fraction take 90 or more.

> **Prep time is right-skewed.** Drinks occasionally go wrong; they never go faster than
> possible. A normal distribution has a left tail, which would produce drinks made in negative
> time.

**Uniform barista skill, U(0.85, 1.20).** Drawn once per station and held for the shift, so a
fast barista is fast all day. That is what makes station utilisation uneven in a way averaging
would hide.

**Exponential pickup delay.** The exponential is the "memoryless" waiting distribution: most
customers collect quickly, a few take much longer, and knowing someone has already waited
three minutes tells you nothing about how much longer they will be. Mean 100s at the kiosk,
180s on the web — web customers are not standing in the shop.

> **Pickup delay** is what exercises the quality timer (§9.6). Without it, no drink ever sits,
> and the cohesion boost has nothing to be measured against.

**Bernoulli remakes, 2% per drink.** A Bernoulli trial is a single weighted coin flip. Each
finished drink gets one; on a hit, the drink is re-queued as a remake on the same order (§5.2),
which is the only path that exercises §6.4's priority floor.

#### Reneging: what it is, and what it is for

The table calls this reneging, which is the term of art for *abandoning a queue you have
already joined*. What is specified — a decision made from the quoted wait, before ordering —
is strictly **balking**: declining to join at all. The formula is the one that matters; the
name is loose, and §17 records both.

`p = clamp((eta − 480) / 1200, 0, 0.8)` — nobody leaves under 8 minutes, and the probability
climbs to a ceiling of 80%.

**It is not a metric an owner can act on directly.** A customer who does not order leaves no
trace: no row, no event, nothing in `scheduler_events`. Making it observable in production
would need a `quote_shown` event alongside `order_placed`, which is a schema and privacy
question this design has not addressed.

**Its job is to correct the other metrics.** Reneging is negative feedback: a longer queue
means a longer quote, which means fewer people join, which stops the queue growing. Remove it
and nothing limits the queue once demand exceeds capacity. Measured, same seeds, one line of
the model changed:

| demand | model | p90 wait | orders served | customers lost |
|---|---|---|---|---|
| ×2.5 | no reneging | **99.8 min** | 961 | 0 |
| | with reneging | **31.1 min** | 814 | 146 |
| ×3.0 | no reneging | **230.9 min** | 1173 | 0 |
| | with reneging | **62.2 min** | 905 | 267 |

Nobody waits four hours for bubble tea. Without reneging the model computes a queue that
cannot physically exist, because the people required to form it would have left.

The consequence is a wrong decision, not just a wrong number. "At three stations, p90 is 100
minutes" sends you hiring two more baristas to fix a queue that would never form. "At three
stations, p90 is 31 minutes and you lose 146 customers" is an actual business question — 146
customers against the cost of one more barista — and it is the question §10.5's staffing curve
exists to answer.

It also breaks calibration in the other direction. Waits measured in a real shop are censored
by this effect: you would record 31 minutes, because the people who would have waited 100 are
not in your data. Fit a model to that without accounting for who left and you conclude demand
is 814 orders when it is 960.

### 10.4 Metrics

Report **p50 / p90 / p99 — never the mean.** The mean hides exactly the failures fair queuing exists to prevent.

**Headline:** small-order p90 wait vs. concurrent large-order rate.
If fair queuing is working, that line is **flat**. If it slopes up, the quantum is too large.

Supporting:

| Metric | Why |
|---|---|
| Wait percentiles by size class (1–2 / 3–6 / 7+ drinks) | the fairness claim itself |
| Station utilization | past ~85% queues grow nonlinearly — this is where staffing decisions get made |
| ETA error (p50 abs) **and bias** (signed mean) | bias is the one that destroys trust |
| Quality-timer breach rate | measures the cohesion boost — which it falsified (ADR-0014) |
| Order cohesion spread (p90 of `ready_at − first_ready_at`) | melted-first-drink problem |
| Remake latency | validates the priority floor |
| Reneged orders | revenue cost of the current staffing |
| Max queue depth, time above depth 15 | KDS legibility under load |

### 10.5 Experiments to ship with the dashboard

1. **Ablation** on a fixed seed: FIFO → DRR → DRR+aging → DRR+aging+cohesion. Four bars, one chart. This is the proof the design works.
2. **Quantum sweep**: 30s → 400s, plot small-order p90 and large-order p90 together. The crossover is your setting.
3. **Staffing curve**: for each hour, minimum stations holding p90 under target. Output is an actual shift schedule.
4. **Breaking point**: raise the demand multiplier until p90 exceeds 15 min. That number is the store's real capacity.
5. **Replay** (later): feed historical `scheduler_events` through the simulator to calibrate σ and validate against what actually happened.
6. **Shadow mode** (later): run an alternate config against live arrivals, log what it *would* have done, compare.

### 10.6 Dashboard UI

**Signature element:** a live station-lane ribbon — one horizontal lane per station, drinks as capsule bars colored by order. A large order's drinks are visibly *interleaved* with small orders' drinks. This makes the fairness claim something you can see rather than infer from a percentile table. Build this first; it will teach you more about the scheduler than any number.

Layout:

```
┌──────────────────────────────────────────────────┐
│ header — scenario name · seed · Run              │
├────────────┬─────────────────────────────────────┤
│  CONFIG    │  VERDICT: small-order p90, flat?    │
│  (rail)    ├─────────────────────────────────────┤
│  demand    │  ▓▓ STATION LANE RIBBON (signature) │
│  stations  ├─────────────────────────────────────┤
│  policy    │  metric grid — percentiles by class │
│  quantum   ├─────────────────────────────────────┤
│  aging     │  blocking chart: FIFO vs DRR        │
│  cohesion  ├─────────────────────────────────────┤
│  large %   │  ablation bars · staffing curve     │
└────────────┴─────────────────────────────────────┘
```

Design constraints: this is an instrument panel, not a marketing page. Tabular-numeral monospace for all figures, hairline rules, one accent color, no gradients. Every run must display its seed. Config changes re-run automatically (the sim is fast enough) with the previous run ghosted behind the current one for comparison.

Ship an **"Apply to store"** action that writes the current config to `stores.scheduler_config`, with a confirmation showing the diff. Never let dashboard state silently become production state.

---

## 11. Testing

**Scheduler unit tests** (pure functions, no DB — these should run in milliseconds):

- One 15-drink order + one 1-drink order arriving 10s later → the single drink dispatches within one quantum.
- Continuous stream of 1-drink orders + one 20-drink order → the large order still completes; assert no starvation.
- Remake outranks all same-age normal work; older remake outranks newer remake.
- Order with `promised_at` two hours out is not eligible until its backward-scheduled start.
- Cohesion: an order past 50% completion outranks an equal-age order at 0%.
- Empty queue returns `nil`, never raises.
- Livelock guard trips rather than spinning.

**Concurrency tests:** N threads calling `ClaimNextDrink` simultaneously → every drink claimed exactly once, zero duplicates, zero errors surfaced to the client.

**Golden tests:** fixed seeds producing byte-identical dispatch sequences. These are what let you refactor the scheduler without fear, and are mandatory if the simulator is client-side.

**Acceptance criteria:**

- Small-order p90 wait is flat (±15%) across large-order rates from 0% to 12%, under DRR, at 3 stations and default demand.
- The same test under FIFO shows a clearly rising line. If it doesn't, the generative model isn't stressing the system and the defaults need revisiting.
- ETA bias converges within ±45s after 200 simulated orders with the EWMA enabled.

---

## 12. Build order

0. **Dev environment as containers.** `docker compose`: Postgres, Redis, Rails, Vite dev server. Write the production Dockerfile now (§14.1 — multi-stage, non-root); the image compose runs is the image Kubernetes will run.
1. **Schema + menu + ordering flow.** Orders land in the DB with correct `prep_seconds`. Payment stubbed as pay-at-counter (§9.3). No scheduler yet — FIFO only.
2. **KDS with FIFO + `SKIP LOCKED`.** Real start/finish, real ActionCable. Now the system works, just unfairly.
3. **Board with naive ETA.** `total_work / stations`. Now it's usable in a store.
4. **Deploy to Kubernetes** (§14): kind cluster, hand-written manifests, CI building and pushing images, admin auth (§13) in place before the first deploy. Every step below ships through the cluster — that repetition is where the k8s learning actually happens.
5. **Scheduler as a pure function**, DRR behind a config flag, with the full unit-test suite. This is the piece to get right; everything after depends on its shape.
6. **Simulator core + lane ribbon.** Validate DRR actually delivers the flat line before trusting it live.
7. **Forward-projection ETA + EWMA learning.** Replace the naive estimate.
8. **Remakes, quality timer, offline handling, SMS (§9.7).**
9. **Full dashboard: sweeps, ablation, staffing curve, apply-to-store.** **TLS via cert-manager must land before this ships** — see §14.5. The dashboard is the first browser surface behind the admin cookie session, and that cookie cannot work over plain http.
10. **Hardening:** rate limiting (§13), Prometheus + Grafana (§15), HPA on `web` (§14.5).

Steps 1–3 give a shop that functions; step 4 puts it somewhere real. Steps 5–6 are where the actual design claim gets tested. Do not skip step 6 and tune in production.

---

## 13. Security & auth

The surface is small, but none of this is optional — "solo learning project" is not a reason to ship an open admin API.

### 13.1 Surface map

| Surface | Access | Mechanism |
|---|---|---|
| `GET /menu`, `GET /board`, `GET /health` | public | none |
| `POST /orders` | public | rate-limited (§13.2) |
| `GET /orders/:pickup_code` | public | `pickup_code` is the capability token — per-store per-day unique, low-value, throttled. 4 chars from a 30-char unambiguous alphabet (no `0/O/1/I/L/B/8`) ≈ 810k codes; with per-IP throttling, enumeration isn't worth anyone's time. |
| `/kds/*` | barista | PIN login → station token (§13.3) |
| `/admin/*` | admin | single admin user, cookie session (§13.4) |

### 13.2 Rate limiting (Rack::Attack)

```ruby
throttle("orders/ip",  limit: 10,  period: 1.minute)  { |req| req.ip if req.post? && req.path == "/api/v1/orders" }
throttle("status/ip",  limit: 60,  period: 1.minute)  { |req| req.ip if req.path.start_with?("/api/v1/orders/") }
throttle("kds_pin/ip", limit: 10,  period: 1.minute)  { |req| req.ip if req.path == "/api/v1/kds/session" }
safelist("kiosk") { |req| ENV.fetch("KIOSK_IPS", "").split(",").include?(req.ip) }
```

The kiosk safelist exists because a busy Saturday from one store IP would otherwise trip the order throttle.

### 13.3 KDS station token

`POST /kds/session` with `{ barista_pin, station_id }` verifies against `baristas.pin_digest` (bcrypt) and returns a signed token (`Rails.application.message_verifier(:kds)`) encoding `{ barista_id, station_id, store_id, exp: 12.hours }`. Sent as `Authorization: Bearer` on every `/kds/*` call and as a param when subscribing to `KitchenChannel`. Wrong-store tokens are rejected at channel subscription, not just at REST.

### 13.4 Admin

One `admin_users` table (`email`, `password_digest` via `has_secure_password`), cookie session, no roles, no signup — created by seed/console. This exists from the first deploy: `PATCH /admin/scheduler_config` changes live scheduler behavior and must never be open even briefly.

### 13.5 Data hygiene

- `customer_phone` never appears in logs (`config.filter_parameters += [:customer_phone]`), API responses (excluded from all serializers except the admin order view), or any broadcast payload. The board privacy rule (§3) extends to every ActionCable channel.
- Secrets come from the environment only (§14.6). `stores.scheduler_config` must never contain a secret.

---

## 14. Deployment — Docker to Kubernetes

Kubernetes is a learning goal in its own right. The sequencing principle: **containerize from day zero, deploy to k8s as soon as the shop functions (build step 4), so every later feature ships through the cluster.** Deploying a finished app once teaches you YAML; deploying twenty incremental changes teaches you Kubernetes.

### 14.1 Images

Two images, built by CI on every push to `main`, tagged with the git SHA (never `latest`):

| Image | Contents | Runs as |
|---|---|---|
| `boba-api` | Rails; multi-stage build (build stage: gems + bootsnap precompile; runtime stage: slim, non-root `rails` user, port 3000) | `web` (`bundle exec puma`) and `worker` (`bundle exec sidekiq`) — same image, different command |
| `boba-frontend` | React static build (Vite `dist/`) served by nginx; nginx config proxies nothing — routing is the ingress's job | `frontend` |

**Background jobs: Sidekiq**, not Solid Queue — Redis is already load-bearing (deficits, ActionCable, debounce locks), and a separate worker Deployment is exactly the topology k8s learning needs. All recurring work (ETA idle tick §7.2, abandoned-order sweep §5.1, quality-timer checks §9.6) runs via `sidekiq-cron`, not cron in a container.

### 14.2 Cluster & manifest layout

Local cluster: **kind**. Write the manifests by hand first — that is the learning — then fold them into Kustomize (`k8s/base` + `k8s/overlays/{dev,prod}`). Helm is for third-party charts only (ingress-nginx, kube-prometheus-stack, cert-manager), never for this app.

| Workload | Kind | Replicas | Notes |
|---|---|---|---|
| `web` | Deployment | **2** | Two from the start, even though one would do — multi-pod flushes out hidden single-process assumptions (§14.4). Serves `/api` and mounts ActionCable in-process at `/cable` with the Redis pub/sub adapter. |
| `worker` | Deployment | 1 | Sidekiq: ETA recomputes, sweeps, SMS, EWMA updates. |
| `migrate` | Job | — | `bin/rails db:prepare`, applied before each web rollout (CI applies the Job and waits for completion, then updates image tags). Never run migrations on container boot. `db:prepare` rather than `db:migrate` because the first deploy has no database to migrate, and the app 404s without a seeded store (`Store.first!`) or an admin user (§13.4) — the seed *is* the bootstrap. On every later run it migrates and nothing else. Needs an init container that waits for Postgres: the `postgres` Service is headless, so its DNS does not resolve until a pod is ready, and the Job otherwise spends its retry budget on `could not translate host name`. |
| `postgres` | StatefulSet + PVC | 1 | In-cluster is fine — and instructive — for a learning project. A real production store would use a managed database; say so in the README and move on. |
| `redis` | StatefulSet | 1 | No persistence needed: every key (deficits, pointer, locks, pub/sub) is reconstructible or ephemeral by design (§6.5). `emptyDir` is acceptable. |
| ingress | ingress-nginx | — | `/api` and `/cable` → `web`; everything else → `frontend`. `/cable` needs websocket-friendly annotations: `proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`. |

**Rollback is bounded by the schema, not by the registry.** The `migrate` Job runs *before* each rollout, and migrations do not revert with the image. Setting `web` back to an earlier SHA leaves the database wherever the failed release left it — so "how far back can I go" is a question about schema compatibility, and CI retaining N image versions has nothing to do with the answer.

That makes the window one release by default, and longer only when a schema change is deliberately split across releases:

1. **Expand.** Add the new column or table, nullable or defaulted. Nothing reads it yet, so the previous image still runs against this schema.
2. **Migrate.** Deploy code that writes both shapes and tolerates reading either. Backfill here if needed.
3. **Contract.** Remove the old column in a *later* release, once nothing running depends on it.

A migration that drops or renames a column in the same release as the code depending on it is a one-way door: the previous image cannot run against the new schema, and the only way out is forward. That is an acceptable trade for some changes — it just has to be a decision rather than a discovery, and the PR's **Risk** section is where it gets recorded.

This starts mattering at build step 5, when the scheduler begins changing schema.

### 14.3 Probes

- `web` **liveness**: Rails' built-in `/up`. Deliberately *not* gated on the database — gating liveness on a dependency means a Postgres blip restarts every pod at once, turning a recoverable degradation into an outage. Restart is the right answer to a wedged process and the wrong one to a sick dependency.
- `web` **readiness**: a separate `/readyz` that runs `SELECT 1` against Postgres and `PING` against Redis, returning 503 with a per-dependency breakdown. This has to be its own endpoint: `/up` returns 200 whenever the app booted and does not touch either dependency, so using it for readiness admits pods with no database into the Service. Redis counts because it is load-bearing, not a cache (§14.4) — a pod that cannot reach it cannot broadcast, cannot take the board's throttle lock, and cannot read the scheduler's deficits.
- `worker` liveness: `sidekiq_alive` gem or a simple `pgrep`-style exec probe; no readiness (it serves no traffic).
- `/api/v1/health` (§9.1) stays **business-level** — it answers "is the store taking orders," which includes `stores.accepting_orders`, not just "is the pod alive." The kiosk polls that one; the kubelet polls `/up` and `/readyz`. Do not conflate them: an owner flipping `accepting_orders` off must not cause k8s to restart pods.

Three endpoints, three questions, and every pair of them is dangerous to merge: *is the process alive* (`/up`), *can this pod serve* (`/readyz`), *is the shop open* (`/api/v1/health`).

### 14.4 Multi-pod correctness

The design is already nearly stateless per-request; three facts make two `web` pods fully safe, and the implementer must preserve all three:

1. **Drink claiming already is** — `FOR UPDATE SKIP LOCKED` (§8) is pod-agnostic by construction.
2. **Scheduler state already is** — rebuilt per dispatch cycle from Postgres, with deficits and pointer in Redis (§6.5), so every pod computes the same schedule.
3. **The ETA debounce is not, unless implemented as specified** — it must be the Redis `SET NX PX` lock from §7.2, never an in-process timestamp.

Plus one k8s-ism: ActionCable **must** use the Redis adapter (`config/cable.yml: adapter: redis`), or broadcasts from pod A never reach subscribers on pod B. With these, the "one process per store" caveat in §16 reduces to Redis key scoping, which the `sched:{store_id}:*` scheme already provides.

### 14.5 Pipeline & later curriculum

- CI (GitHub Actions, one workflow): test → build both images → push to GHCR → `kubectl apply -k k8s/overlays/prod` with the new SHA tag (via `kustomize edit set image`). No progressive delivery, no ArgoCD — this project doesn't need them; add them later *as* curriculum if desired.
- **cert-manager + real TLS on the ingress is not optional curriculum, and it cannot wait for step 10.** Two things break on plain http, and both are silent:
  - **ActionCable refuses the connection.** Its production origin check allows same-origin over *https* only, so every websocket upgrade is rejected with `Request origin not allowed`. The board and KDS render their first paint from REST and then never update — §14.4's failure mode reached by a different route, with no error anywhere the user can see. Until TLS exists, `ACTIONCABLE_ALLOWED_ORIGINS` (ConfigMap, comma-separated) must name the http origin explicitly. It defaults to Rails' strict behaviour so that forgetting it fails closed.
  - **The admin session cookie is dropped.** `force_ssl` marks it `Secure`, and browsers refuse to store `Secure` cookies from an http origin. Admin sign-in works with `curl` and silently does not work in a browser. **Do not weaken the cookie to work around this** — §13.4's whole point is that the surface changing live scheduler behaviour is not casually reachable. Ship TLS instead, before the step 9 dashboard.
- Later, in order of learning value: kube-prometheus-stack (§15) → HPA on `web` (CPU-based is fine; the app is stateless per-request) → PodDisruptionBudget on `web`.

### 14.6 Configuration

- **Secret** (k8s Secret): `DATABASE_URL`, `REDIS_URL`, `RAILS_MASTER_KEY`, `SEED_ADMIN_PASSWORD`, later `TWILIO_*`. Postgres' own `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` belong here too, beside `DATABASE_URL` rather than split into the ConfigMap — a connection string and the `initdb` values that have to agree with it drift the moment they live in two objects.
- **ConfigMap**: `RAILS_ENV`, `KIOSK_IPS`, log level, `ACTIONCABLE_ALLOWED_ORIGINS` (§14.5).
- `SEED_ADMIN_PASSWORD` is deploy-critical, not a convenience: `db/seeds.rb` falls back to a placeholder, and with `db:prepare` in the rollout path (§14.2) that fallback becomes the live admin password on the first deploy.
- `stores.scheduler_config` stays in Postgres — it is runtime tuning owned by the dashboard's "apply to store" flow (§10.6), not deploy config. Never move it to env.

---

## 15. Observability

The simulator already defined what matters (§10.4). Production watches **the same metrics under the same definitions** — if the dashboard number and the prod number can't be laid side by side, one of them is wrong.

- **Logs:** structured JSON (lograge), tagged with request id and `store_id`. `customer_phone` filtered (§13.5).
- **Metrics:** Prometheus via `yabeda-rails` + `yabeda-sidekiq` + `yabeda-prometheus`, scraped from `/metrics` by kube-prometheus-stack. Beyond the framework defaults, emit the business gauges/histograms from §10.4: queue depth, wait-time histogram labeled by order-size class, ETA signed error, quality-breach counter, remake counter. One Grafana dashboard mirroring the §10.4 headline chart (small-order p90 vs. large-order rate).
- **Errors:** Sentry (free tier), wired in at deploy time (build step 4), not after the first silent 500.
- **Retention:** `scheduler_events` is the audit trail and replay source; it grows forever by design. At this volume that's megabytes per month — ignore it until it hurts, then prune rows older than 12 months. Never prune before replay calibration (§10.5 #5) has used them.

---

## 16. Open questions

- **Multi-station specialization.** Slushes need a blender; if there's one blender, stations aren't interchangeable. Model as station capabilities and item requirements, or keep stations uniform for v1? Recommend uniform for v1, with `MenuItem#required_capability` nullable in the schema so it can be added without a migration cascade.
- **Payment failure after order placement.** Void and remove queued items, or let the drink finish and settle at the counter? Affects whether `placed` implies `queued`.
- **Order modification after placement.** Currently unsupported. If added, only items still in `queued` can change.
- **Multi-store.** Schema is store-scoped throughout, and §14.4 removes the one-process-per-store assumption for a single store's pods. True multi-store mostly reduces to what's already namespaced (`sched:{store_id}:*` Redis keys, store-scoped channels); the real gaps are request routing to a store and admin scoping. Revisit before store #2.
- **A customer's estimate rises when someone orders behind them.** Fair queuing shares capacity with new arrivals, so an order already in the queue genuinely gets slower when the shop gets busier — unlike FIFO, where arrival order is final. §10.5 measures the effect (above) and §9.3 now leads with a monotone progress count rather than a countdown, but the underlying question is unanswered: should a customer ever be shown a number that can move against them, or is the promise made at order time (`quoted_wait_seconds`) the only figure they should see? Revisit with real customers rather than by argument.
- **Peak-hour large-order policy.** Should catering orders above N drinks require a `promised_at` during peak windows? This is a business rule, but the scheduler already supports it via backward scheduling.
- **Service mesh.** Considered and deferred. There is almost nothing to mesh: the only in-cluster hops are `web`/`worker` → Postgres and Redis, both TCP, so a mesh contributes L4 mTLS and none of the L7 retries, routing, or golden signals that justify one. Its metrics also do not answer §15's questions, which are business gauges under the simulator's definitions (§10.4). Two sharp edges if adopted anyway: a sidecar keeps the `migrate` Job (§14.2) from ever completing unless native sidecars are used, and ActionCable's shift-long websockets are a known source of idle-timeout trouble. The one real gap it would close is outlier ejection — readiness removes a pod that has lost a dependency, but not one that is Ready and serving 500s. That is not enough to carry the cost. Belongs after everything in §14.5, and after hitting a problem that calls for it.

---

## 17. Glossary

Terms used above that are standard in queueing theory or networking, and are not otherwise
common. Ordered roughly by where they first appear.

**Flow** — in fair queuing, one competing stream of work. Here, one **order** (§6.1). The
whole design follows from choosing the order rather than the drink as the flow.

**Deficit Round Robin (DRR)** — a fair-queuing algorithm that shares capacity between flows
whose items are different sizes, by giving each flow a credit allowance per round and carrying
the unspent remainder. Explained with worked examples in §6.1.

**Quantum** — the credit, in prep-seconds, a flow receives on each turn of the ring. Default
120 (§6.6).

**Deficit** — a flow's unspent credit, carried between rounds. The property the algorithm is
named for: without carrying, a flow whose drinks cost more than one quantum would starve
forever.

**Ring / ring pointer** — the rotation through flows, and the position within it. Persisted as
an order id rather than an array index, because indices are meaningless once the flow set is
rebuilt (§6.5).

**Aging** — growing a flow's quantum with how long it has waited, so nothing starves under a
continuous stream of newcomers (§6.1, §6.2).

**Cohesion** — boosting a flow that is already more than half made, so its remaining drinks
finish rather than being interleaved away. Exists for the *melted first drink* (§6.1, §6.4).

**Priority floor** — a guarantee that one class of work outranks another regardless of age.
Implemented as a sort tier, because any number added to a multiplier can be exceeded by a
sufficiently aged competitor (§6.4, ADR-0009).

**Livelock** — a loop that keeps running without making progress. §6.2's guard raises rather
than spinning, because a stalled kitchen that reports nothing is worse than a crash.

**Utilisation (ρ, "rho")** — the fraction of capacity in use: total work divided by
(stations × time). ρ = 0.6 means the shop is busy 60% of the time.

**Kingman's formula** — the result that waiting time scales with **ρ / (1 − ρ)**. The
practical consequence is that queues do not grow smoothly: going from ρ = 0.5 to 0.6 roughly
doubles the wait factor, but 0.9 to 0.95 doubles it again from a far higher base. This is why
§10.4 says queues grow nonlinearly past ~85%, and why it is where staffing decisions get made.

**Little's Law** — **L = λW**: the average number of orders in the shop equals the arrival
rate times the average time each one spends there. It holds for *any* arrival process and
*any* service distribution, which makes it the strongest available check that a simulator's
bookkeeping is sound — it can catch orders being double-counted, dropped, or timed against the
wrong clock. It is necessary and not sufficient: a model with the wrong service times still
satisfies it.

**Percentile (p50 / p90 / p99)** — the value below which that share of observations fall. p90
= 200s means nine customers in ten waited less than 200 seconds. §10.4 reports percentiles and
never the mean, because the mean hides exactly the failures fair queuing exists to prevent.

**Poisson process** — events arriving independently at some average rate. **Non-homogeneous**
means the rate varies with time. **Thinning** is the sampling technique: generate at the peak
rate and probabilistically discard to match the current one (§10.3).

**Heavy-tailed** — a distribution where rare large values are common enough to dominate the
total. 3% of orders being 8–20 drinks carries about a quarter of the shop's work (§10.3).

**Lognormal** — a bell curve on the logarithm of a value, giving a floor at zero and a long
tail on the high side. Used for prep times, which can run over but never under (§10.3).

**Exponential** — the memoryless waiting distribution: how much longer you will wait does not
depend on how long you already have. Used for pickup delay (§10.3).

**Bernoulli trial** — a single weighted coin flip. Used for the 2% per-drink remake rate
(§10.3).

**Balking / reneging** — *balking* is declining to join a queue; *reneging* is abandoning one
already joined. §10.3's table says reneging, but the specified behaviour — deciding from the
quoted wait, before ordering — is balking. Both names appear here so the mismatch is not
mistaken for two mechanisms.

**Mutation testing** — deliberately altering code and checking whether the tests notice. A
surviving mutant means no assertion depended on the altered expression. Scoped to the
scheduler (ADR-0002), with the rationale and the equivalent-mutant caveat in
`docs/testing.md`.

**Common random numbers (CRN)** — a variance-reduction technique for comparing two
configurations of a simulation: give both the *same* random draws, so the difference between
them is attributable to the change and not to luck. The subtlety is that a single shared
generator does not achieve this — if a change reorders when draws happen, the two runs
consume the stream differently and diverge. The fix is an independent substream per entity,
so a draw about a given drink is the same draw whenever that drink is made (ADR-0011).

**Round robin (RR)** — serve one item from each queue in turn, then start again. Fair in
*turns*, which is only fair in *time* if every item costs the same. DRR is RR plus a deficit
counter, which is what converts equal turns into equal time (§6.3, ADR-0013).

**Shortest job first (SJF)** — always serve the cheapest waiting item. Minimises mean wait,
provably so on one server, and starves anything expensive while doing it. Kept as a benchmark
arm rather than a policy: it bounds what fairness costs (§6.3).

**Starvation** — a queue that never gets served because something is always ahead of it. The
failure every fair-queueing algorithm exists to rule out, and what §6.2's aging guarantees
against.

**EWMA (exponentially weighted moving average)** — a running average that forgets old data
smoothly. Each new observation takes weight `α` and everything already known takes `1 − α`, so
at §7.3's `α = 0.2` the most recent sample counts for 20%, the one before it 16%, and about
90% of the value comes from the last ten observations. Preferred over a plain mean because a
mean over a thousand drinks barely moves for the next one — a new barista or a changed recipe
would take a month to appear — and over "the last N samples" because it is a single number per
menu item rather than a stored window (§7.3).

**Leading-edge throttle / trailing flush** — a rate limit that publishes the *first* event in
each window immediately, then, if more arrive during that window, publishes once more when it
closes. The leading edge is what keeps the display responsive; the trailing flush is what
stops the *last* event in a burst from being dropped, which is the one that says a drink is
ready (§9.2, §7.2). Distinct from a plain throttle, which drops everything after the first,
and from a debounce, which waits for quiet and so publishes nothing at all under sustained
load.

**Fanout** — how many recipients one event has to be delivered to. `BoardChannel` and
`KitchenChannel` are one stream per store, so a transition is one publish; `OrderChannel` is
one stream per order and every transition changes every order's `eta_seconds`, so its fanout
is the number of open orders (ADR-0016).
