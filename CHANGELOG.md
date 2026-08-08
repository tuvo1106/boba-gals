# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are written for someone **operating the shop**, not for someone reading the diff.
Cite the `DESIGN.md` section a change implements.

<!--
Categories, in this order:
  Added       — new features
  Changed     — changes to existing behavior
  Deprecated  — soon-to-be-removed features
  Removed     — removed features
  Fixed       — bug fixes
  Security    — vulnerabilities and hardening
-->

## [Unreleased]

### Added
- The kitchen display exists (§9.4). Baristas sign in with a station and PIN and get a single
  lane of drink cards — drink name, options as bold tokens, pickup code, and position within a
  multi-drink order so it is obvious when the scheduler is interleaving one. One tap starts a
  drink, one tap finishes it, no confirmation dialogs, and a 60-second undo is the escape
  hatch. A "Next up" section always shows the next three so cups and toppings can be
  pre-staged. The header carries queue depth and the oldest wait, and nothing else.
- The shop learns how long its drinks actually take. Every finished drink updates a running
  average per menu item, and once there are ten of them the board quotes from what the shop
  really does rather than from the seeded guess (§7.3). Durations wildly out of line with the
  recent average — a barista who forgot to tap "finish" — are discarded rather than learned
  from. Progress is visible at `/api/v1/admin/prep_time_stats`.
- A drink-cost penalty on the dashboard: how much longer a small order queues when it
  ordered slow drinks rather than quick ones. It is the only figure that separates the
  scheduling policies at the shop's normal demand — SJF reads 8.5× where every wait
  percentile says it is the best policy on the board (§6.1).
- Two comparison arms in the simulator, `rr` and `sjf` (§6.3, ADR-0013). Plain round robin is
  DRR without the deficit, so it isolates what the deficit is worth — 19% off small-order p90
  at 80% utilisation. Shortest-job-first is the mean-wait floor, so "DRR beats FIFO" becomes a
  position on a scale rather than a comparison against the worst option. Both are
  simulator-only; the store still accepts `drr` and `fifo` only.
- Simulation dashboard can scrub to any part of the day, with the hourly arrival
  profile drawn into the control so the peaks are findable rather than guessed (§10.6).
- "Find order" jumps the ribbon to where a given order was actually made and keeps
  it highlighted — an order-ahead order is dispatched hours after it arrives, so its
  id says nothing about where to look (§10.3, §10.6).
- Station count and demand multiplier are adjustable, so utilisation can be pushed
  past §10.4's 85% knee and the nonlinear jump in waits and walkaways is something
  you do rather than read about (§10.6).
- Hovering a drink in the lane ribbon names its order and highlights every other
  drink in that order across all stations, so you can trace one catering order
  through the shift (§10.6).
- Every figure under the ribbon now says what it measures and which direction is
  good — utilisation, for instance, turns amber past 70% and red past 85%, where
  §10.4 says queues start growing nonlinearly (§10.6).

- A simulation dashboard showing what the kitchen actually did (§10.6): one row per station,
  every drink a coloured capsule, coloured by which order it belongs to. Switching between
  fair queuing and first-come-first-served on the same day makes the difference visible —
  under first-come one order holds a station while everyone waits; under fair queuing the
  colours alternate. The wait figures move with the picture.

- The simulator now models the whole shift, not just the making of drinks (§10.2, §10.3):
  drinks occasionally go wrong and get remade, customers take a while to collect, some order
  ahead for a later pickup, and some look at the quoted wait and decide not to order at all.
  That last one matters most — without it, being slow costs nothing on paper.
- Reports how often a finished drink sat past its quality limit before collection, and how
  many customers were lost to long waits (§9.6, §10.4).

- A simulator that runs the real scheduler against a generated day, so staffing and tuning
  decisions can be tested before they are made in the shop (§10.1, §12 step 6). An eleven-hour
  day takes 7 milliseconds, which is what makes sweeping hundreds of configurations practical
  rather than trying three and guessing.
- Every run is reproducible from its seed, so a bad day can be replayed exactly instead of
  described (§10.2).
- Results report the 50th, 90th and 99th percentile wait — never an average — broken out by
  order size, because an average hides precisely the customers fair queuing exists to protect
  (§10.4).

- The kitchen now decides what to make next by fair queuing rather than strict order of
  arrival, and this is now what the "start next drink" button actually uses (§6.1, §8,
  §12 step 5). A customer who orders one drink behind a fifteen-drink
  catering order waits about one drink, not fifteen — while the catering order still
  finishes rather than being pushed back indefinitely by a stream of small ones.
- Remade drinks jump ahead of ordinary work of the same age, and an older remake goes before
  a newer one, so the customer whose drink was dropped ten minutes ago is served before the
  one dropped a minute ago (§6.4).
- An order that is more than half made gets finished rather than left to sit, which is what
  stops the first drink melting while the last is still being poured (§6.4, §9.6).
- Orders placed for a later pickup are not started early. The shop works backwards from the
  promised time so an 11am collection is not made at 9am (§6.2).
- Strict order-of-arrival remains selectable as a setting, both as a fallback and as the
  comparison the fairness claim is measured against (§6.3).

- Every change is now deployed to a throwaway Kubernetes cluster and exercised before it
  can be merged: an order is placed through the front door, the health checks are read, and
  the cache is pulled out from under the running system to confirm it steps aside rather
  than falling over. Container images are published on each merge, tagged with the exact
  commit they were built from, so what is running is always traceable (§14.1, §14.5).
- The shop runs on Kubernetes (§14.2, §12 step 4). `bin/k8s-up` builds both images, brings
  up a local cluster and deploys the whole system — two API pods, a background worker, the
  web frontend, Postgres and Redis — reachable at http://localhost:8080. `bin/k8s-down`
  takes it away again, either the app alone or the whole cluster.
- The API now reports whether it can actually serve, not just whether it started. A pod
  that has lost its database or Redis is taken out of rotation instead of receiving
  requests it can only fail (§14.3, ADR-0008). A brief database problem no longer restarts
  every pod — it just pauses traffic to them until it clears.
- Schema changes run as their own step before new code goes live, and wait for the database
  to be accepting connections first, so a slow-starting database no longer fails a deploy
  (§14.2, ADR-0007).

### Fixed
- Wait percentiles are reported by the number of drinks the customer *ordered*. A remake adds
  a drink to the order (§5.2), which moved remade 2-drink orders out of the "1–2" class — and
  since remade orders are slow ones, that made the headline small-order figure look about 2%
  better than it was.
- The dashboard no longer presents a "7+ p90" computed from five orders as if it were a
  percentile. Below ten samples nearest-rank returns the maximum, so all four policies were
  showing the same single worst catering order. Every wait figure now carries its sample
  count, and says so when there are too few.
- The dashboard says when the shop is too quiet to compare scheduling policies at all. At the
  default demand utilisation is 34%, there is rarely a queue, and every policy dispatches
  almost the same order — which read as "SJF beats DRR" rather than "this run cannot tell".
- Simulation A/B comparisons are now honest. Changing the scheduler used to change *which
  drinks the day contained* — at one seed only 105 of 740 drinks kept the same prep time
  between DRR and FIFO, so every comparison mixed the policy effect with a different random
  day. Runs now draw from per-entity random substreams (ADR-0011). Figures from earlier runs
  should be re-measured, not compared against.
- The quality timer counts one breach per stale drink rather than one per stale order, as
  §9.6 specifies. A 20-drink order where nineteen drinks went stale scored as a single breach.
- "Sat too long" is now reported over multi-drink orders, where cohesion can actually change
  it. A lone drink's counter time is just the customer walking over, which put a floor near
  10% under the old figure and hid the signal.
- An order promised a pickup time after closing was never dispatched and never counted — it
  was neither served nor lost, and vanished from every metric.
- `bin/rspec` forces `RAILS_ENV=test`. The dev container sets `RAILS_ENV=development`,
  which made `rails_helper.rb`'s `||=` default a no-op: Bundler skipped the `:test`
  gem group, every Rails spec failed to load, and anything that did load ran against
  the development database.

- A barista tapping "start next" could be told the queue was empty while drinks were still
  waiting, if other baristas happened to be tapping at the same moment. The retries meant to
  cover that case all fired within a few microseconds of each other — inside the split second
  a colleague's tap holds the drink — so they were spent before the drink was ever released
  (§8).

- Live updates would have stopped working the moment the shop moved off a laptop. The
  kitchen and board keep themselves current over a websocket, and the server refused every
  one of those connections when running behind the cluster's ingress — so both screens
  would have shown whatever was true when they were opened and never changed. The board
  gives no sign of this; it just quietly goes stale (§14.4).

- Admin sign-in and scheduler configuration (§13.4, §12 step 4). The owner can read and
  change how the scheduler behaves — quantum, aging, cohesion, the remake priority floor —
  without a console. This is locked behind a password from the first deploy, because those
  settings change how the shop runs while it is running.
- Configuration changes are checked before they apply. A value that would invert the remake
  priority floor (§6.4) or quote customers a shorter wait than the estimate (§7.3) is
  refused with the reason, and a setting the scheduler doesn't have is refused rather than
  quietly stored — nothing that isn't scheduler tuning can end up in there (§14.6).
- Learned prep times are visible (§7.3): what the shop seeded, what it has observed, how
  many samples, and whether that is yet enough to trust. Empty until the EWMA lands at
  build step 7 — it ships now because "is the ETA wrong because the prep times are wrong"
  is the first question anyone asks, and it shouldn't need a console to answer.

- Customer board (§9.5, §12 step 3): two columns readable across the shop, showing who is
  waiting and who can collect. Names appear as first name and pickup code only — if two
  Sarahs are waiting, the code tells them apart (§3).
- Waits are shown in whole minutes, and anything under two minutes reads "Almost ready".
  A countdown by the second would be false precision, and customers learn to distrust it.
- The board updates itself as drinks are placed, started, and finished. A screen left on
  the wall all day needs no attention: it reconnects on its own and shows a quiet
  "Reconnecting…" to staff while it does.
- A ready name stays on the board for five minutes and then makes room for the next one.
  Pickup is not tracked — nobody taps anything at handoff (ADR-0005).
- Estimated waits account for the queue in front of an order rather than the shop's total
  workload, so the next order and the tenth show different numbers (ADR-0004). Order-ahead
  orders no longer inflate the wait for everyone standing at the counter.

- Kitchen display: a barista signs in with a PIN at a station, taps once to start the next
  drink and once to finish it, and can undo a mistap for 60 seconds. No confirmation
  dialogs anywhere (§9.4, §12 step 2).
- The kitchen screen updates live over ActionCable and always shows the next three drinks,
  so a barista can pre-stage cups and toppings — which is where real throughput comes from
  (§9.2, §9.4).
- Two baristas tapping "start" at the same moment now each get a different drink rather
  than one of them getting an error. Verified with a threaded test: every drink claimed
  exactly once, no duplicates, no errors (§8, §11).
- Order status is derived from its drinks, so an order becomes partly ready, then ready, on
  its own — and an undone finish correctly moves it back (§5.1, §5.2).

- Customers can place orders from the kiosk or the web (§12 step 1). Each drink is
  recorded as its own unit of work with its prep time frozen at ordering — base time plus
  the effect of every chosen option, so extra pearls really does mean fifteen more seconds
  (§2, §4.1).
- Menu endpoint exposing drinks, option groups, and availability, including the
  selection limits the ordering screen uses to decide between single- and multi-choice
  controls (§9.1).
- Order lookup by pickup code, which acts as the access token — scoped to the current day,
  so yesterday's code cannot read today's order (§13.1).
- Kiosk health endpoint reporting whether the store is taking orders. It answers a business
  question, not a "is the server alive" one, so switching ordering off never looks like an
  unhealthy pod (§9.1, §14.3).
- Full schema for stores, menu, orders, staff, prep-time statistics, and the append-only
  scheduler event log, with the partial indexes the hot queries need (§4.1, §4.2).
- Seed data with a real spread of prep times — 40 seconds for a Thai tea, 95 for a brown
  sugar pearl drink. A menu where everything takes the same time would hide the problem
  the scheduler exists to solve (§1).
- Payment recorded as pay-at-counter behind a provider port, so terminal and Stripe
  integrations can arrive later without touching the ordering flow (§9.3).

- Containerized development environment (§12 step 0): `docker compose` runs Postgres,
  Redis, the Rails API, a Sidekiq worker, and the Vite dev server. The `api` and `worker`
  services run the same image with different commands, matching the production topology
  (§14.1).
- Production images for both `boba-api` (multi-stage, non-root) and `boba-frontend`
  (Vite build served by nginx), per §14.1.
- Rails 8.1 API application on PostgreSQL and Redis, with Sidekiq for background work —
  no Solid Queue/Cache/Cable and no Kamal, per the design's locked Rails 8 note.
- React 19 + TypeScript + Tailwind v4 frontend, with kiosk (64px) and web (44px) hit-target
  minimums defined as theme tokens (§9.3, ADR-0003).
- Test infrastructure: RSpec, FactoryBot, shoulda-matchers, and the ADR-0002 coverage
  gates enforced in-process; Vitest and Testing Library for the frontend.
- Ruby and Node versions pinned in `.ruby-version` and `.node-version`, read by mise
  locally, by CI, and by both Dockerfiles.

### Fixed

- Live kitchen updates would have failed in development and production with a gem loading
  error. The Redis client was pinned a major version ahead of what ActionCable accepts, so
  the pub/sub adapter §14.4 requires could not load — and the test suite could not see it,
  because tests use a different adapter. Caught by exercising the running container.

### Changed
- The simulation dashboard is quieter. Every figure carried three lines of explanation, above
  a stack of banners that pushed the lane ribbon — the thing the page exists for — most of the
  way down the screen. The explanations are now behind a `?` toggle (or a hover), and the
  duplicated warnings are one line that only appears when it applies (§10.6).
- Wait times keep updating while a barista is mid-drink. Previously the board's numbers only
  moved when something happened — a drink starting or finishing — so a customer watching a
  95-second drink being made saw a frozen countdown, and a drink running over its estimate
  never corrected until it landed. A tick every 30 seconds now refreshes them (§7.2).
- Placing an order is no longer slower when the shop is busier. Working out wait times means
  simulating the queue forward, which costs 3ms when quiet but 175ms with 436 drinks waiting —
  and it was running inside the request that placed the order. It now runs in the background,
  at most once every 2 seconds per store, with the board reading the latest result (§7.2).
- Opening or closing a bar updates every wait time on the board immediately, rather than at
  the next drink transition (§7.2).
- Wait times on the board and at the counter are now projected by running the real scheduler
  forward over the current queue, rather than dividing outstanding work by the number of
  stations (§7.1). The old estimate quoted by queue position, so it told a customer with one
  drink behind a 15-drink catering order that they were fifteenth in line — when fair queuing
  will actually interleave them almost immediately. It also stays right when the scheduler is
  retuned, which a formula cannot.
- The cohesion boost is off by default. It was meant to stop an order's first drink melting
  while the rest were made; measured over 20 seeds it makes that wait steadily *worse* as the
  boost rises, in every order size, at every load — including the four-drink case it was
  designed around. Shops running it will see catering orders finish sooner (ADR-0014).

- Placing an order now reaches the kitchen and the board immediately. Previously the KDS
  only learned about it when someone refreshed (§9.2).
- The wait quoted at ordering time now includes the safety margin the board uses, so the
  number a customer is told and the number they then watch are computed the same way
  (§7.1). ETA error and bias are measured against that quote (§10.4), and comparing two
  differently-computed numbers would have made the metric meaningless.
- ActionCable now uses the Redis adapter in development as well as production. The async
  adapter is single-process, so it would work locally and silently fail across the two
  `web` pods the design runs from the first deploy (§14.4).
- `bin/docker-entrypoint` no longer runs `db:prepare` on boot. Migrations belong to the
  `migrate` Job applied before each rollout (§14.2).
- DESIGN.md's stack line now reads React 19 rather than React 18. Nothing in the design
  depends on the version, and shadcn/Radix — which ADR-0003 commits to — target 19.

- Project workflow scaffolding: `CLAUDE.md`, PR template, ADR log, testing conventions,
  and this changelog.
- CI pipeline running rubocop, RSpec with coverage gates, and the frontend lint/type/test
  suite. Jobs are guarded on the files they need, so CI is green until the app lands (§12).
- Git hooks via lefthook: conventional-commit validation, lint autocorrect on staged files,
  and a guard against committing secret files (§14.6).
- Quality-gate decisions recorded in [ADR-0002](docs/adr/0002-quality-gates.md): SimpleCov
  thresholds, mutation testing scoped to the scheduler, rswag-generated API docs.
- Frontend styling decision recorded in
  [ADR-0003](docs/adr/0003-tailwind-with-shadcn-as-needed.md): Tailwind project-wide from
  build step 1, with shadcn/ui components pulled in individually where they earn their
  place (§9.3, §10.6).

[Unreleased]: https://github.com/tuvo1106/boba-gals/compare/HEAD...HEAD
