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
- **`web` autoscales on CPU, with a disruption budget guaranteeing at least one pod stays up
  during a drain or rollout** (§14.5, ADR-0027). `minReplicas: 2` keeps the two-pod floor
  §14.2 has always required; `maxReplicas: 6` is sized off Postgres' connection ceiling, not
  a traffic guess. `metrics-server` joins the local kind cluster (`bin/k8s-up`) so the
  autoscaler has real CPU numbers to read, the same way `kube-prometheus-stack` was added
  for Prometheus.
- **`worker` now exports its own Prometheus metrics** (§15, ADR-0026): job counts, queue
  latency, and retry/dead totals from `yabeda-sidekiq`, on a standalone exporter thread
  since `worker` runs no HTTP server of its own to mount `/metrics` on the way `web` does.
  Closes the gap ADR-0025 deliberately left open when the business gauges shipped.
- **Production exports the business metrics §15 asks for, scraped by Prometheus and charted
  in Grafana** (§15, §10.4). Beyond yabeda-rails' framework defaults: kitchen queue depth,
  a customer wait-time histogram by order size class, ETA signed error against the quote
  given at placement, and running totals of quality breaches and remakes. One Grafana
  dashboard mirrors §10.4's headline — small-order p90 wait next to the concurrent
  large-order rate, the live analogue of the simulator's swept `large_order_rate` parameter.
  The four "current total" gauges are computed fresh from Postgres on every scrape rather
  than incremented in-process, because one of their sources (the quality-breach sweep) runs
  on `worker`, which has no metrics exporter yet — ADR-0025 has the reasoning. `kube-prometheus-stack`
  installs via Helm into the local kind cluster (`bin/k8s-up`, skipped in CI — real memory
  weight the cluster smoke test doesn't need to prove the app side works).
- **The KDS flags a drink that's been sitting too long while the rest of its order is still
  being made** (§9.4, §9.6). A periodic sweep finds finished drinks past `quality_limit_seconds`
  (default 5 minutes) whose order is still waiting on a sibling and logs one breach per drink
  to `scheduler_events`; the marker then rides on whatever's left of that order still on the
  display, since a fully-finished order has no KDS row at all (ADR-0005) by the time the breach
  is caught. This closes a gap from build step 8: `quality_breach` was reserved as an event type
  and `quality_limit_seconds` as a config key, but nothing live ever produced one — the only
  breach detection that existed was the simulator's. Deliberately scoped narrower than the
  simulator's own metric: without a live pickup signal (ADR-0005), a finished drink whose order
  has already reached `ready` might already be collected, so this only ever flags the case it
  can be sure about. ADR-0024 has the reasoning.
- **The dashboard can push a policy change to the live store** (§10.6). "Apply to store" sits
  in its own labelled box, separate from the simulator controls above it, and shows the diff
  — live policy versus what's on the rail — before writing anything; nothing is sent until
  that's confirmed. Disabled outright for RR or SJF, since those are simulator-only comparison
  arms the server has always refused. Deliberately thin for now: quantum, aging, and cohesion
  stay experiment-only rather than becoming rail controls, since the rail never had a
  persistent value for them to begin with — ADR-0022 has the reasoning.
- **The dashboard can find how much demand a config can actually take** (§10.5). One click
  raises demand from 0.5x to 3x and reports the first point where the typical customer's
  wait crosses 15 minutes (5 and 10 are also selectable) — the shop's real capacity under
  that many stations, not just whether large orders are being treated fairly. A config that
  still holds at 3x is reported honestly as "not reached" rather than guessed at. ADR-0021
  has the reasoning for reading overall wait rather than the fairness headline, and for why
  the search stops at 3x: dispatch cost rises worse than linearly with demand once queues
  get deep, so a run at 5x costs about 80 seconds where 0.5x costs 30 milliseconds.
- **The dashboard can turn a day's simulation into a shift schedule** (§10.5). One click runs
  every open hour at one to eight stations and reports the fewest that keep that hour's p90
  under a target you pick — 5, 10, or 15 minutes. An hour that still misses target at eight
  stations is marked rather than silently shown as "fixed by adding baristas", since nothing
  past eight was ever tried. The method runs the whole day at each station count rather than
  varying staff mid-shift, which the simulator cannot yet do — ADR-0020 has the reasoning and
  what a truer version would need.
- **The dashboard can sweep the quantum and show where small orders start losing to large
  ones** (§10.5). One click runs the same day at ten quantum settings from 30s to 400s and
  charts small-order p90 against large-order p90 together — each on its own scale, since
  catering orders run several times longer by nature. Every point shares the same simulated
  customers, so a difference between two points is the quantum and not a luckier Tuesday.
  This is the evidence owed for why the shipped default sits at 60s rather than somewhere
  else on that range.
- **The dashboard shows how long every size of order waited, not just two of them** (§10.4).
  The simulator has always measured typical / 9-in-10 / 99-in-100 waits for small, medium
  and catering orders — nine figures — and the screen showed two. Mid-size orders were
  invisible, so a scheduler starving them could not be seen. A class with too few orders to
  support a percentile is marked rather than presented as one.
- **The dashboard scores the wait the customer was quoted** (§10.4, §7.3). Three figures:
  the typical miss, the worst tenth, and whether the shop runs systematically **late or
  early** — the last being the one §7.3 says decides whether people trust the board. Quotes
  from a shop so backed up that the estimate stops meaning anything are excluded and
  counted, rather than quietly averaged in.
- **The dashboard can run the same day six ways and chart the difference** (§10.5, §6.3).
  One click compares first-come-first-served against round robin, the deficit, aging and
  cohesion — every arm serving the identical stream of customers, so a gap between two bars
  is the mechanism and not a luckier Tuesday. Shortest-job-first is charted alongside them
  as a benchmark, set apart because it is not something the shop can be switched to.
- The comparison can be read two ways: **by order size** ("does a catering order block the
  person behind it?") and **by drink cost** ("does your wait depend on what you ordered?",
  §6.1). Shortest-job-first looks like the best row on the first and is far and away the
  worst on the second, which is the whole reason both are offered (ADR-0013).
- The comparison pools up to 25 days. One day cannot tell a real improvement from noise, so
  the chart says so until the day count is raised.

- **The simulation dashboard has a sign-in** (§13.4). It could only be reached by someone
  willing to authenticate with a command-line tool first — the screen said "sign in as admin
  first" and offered nothing to sign in with. It now asks for an email and password, shows
  who is signed in, and has a way out, so a back-office machine is not left sitting on a
  screen that can retune the live kitchen. Signed out, the panel is not shown at all rather
  than shown with every control dead.
- **Web customers get one text when their order is ready** (§9.7). Exactly one, whatever
  happens afterwards — a barista who taps Done, undoes it, and taps Done again does not text
  the customer twice. Kiosk orders are not texted, because there is nobody to text. Until
  Twilio credentials exist the message is written to the log instead of sent, and the log
  never contains the phone number (§13.5). A failed send never holds up the order.
- **The kiosk refuses orders when it can't reach the shop** (§9.3, locked in §3). It checks
  every ten seconds and, after two failures in a row, shows a full-screen "Ordering is
  paused — please order at the counter" instead of letting someone build an order that
  cannot be placed. One dropped request is ignored, because shop wifi drops one request. The
  cart is kept, so a brief blip does not cost a customer their order, and the screen clears
  the moment the shop answers again. It also appears when the shop is reachable but has
  ordering switched off — with wording that says so, rather than blaming the network.
- **Baristas can remake a drink that went wrong** (§5.2, §9.4). A "Problem" button on each
  drink card asks why — spilled, wrong drink, not right — and queues a fresh one straight
  away. The replacement jumps ahead of ordinary work of the same age, so the customer whose
  drink was dropped is not sent to the back of the line (§6.4). The original is kept as a
  record rather than erased, which is what keeps the shop's prep-time learning honest: a
  spill is not how long a drink takes. The customer sees the replacement in place of the
  drink that failed, not both.

- **You can order a drink.** The menu, options, cart and checkout now exist as screens rather
  than as endpoints — `/order` on a phone, `/kiosk` in the shop, one build serving both
  (§9.3). Options render the control the menu asks for, so a new option group appears
  correctly without a code change. Payment is at the counter, as designed; there is no card
  field. Placing an order lands on a screen showing the pickup code and every drink's
  progress, reachable again later at `/order/<code>` with nothing but the code from the
  receipt. Sweetness and ice come preselected and there is a quantity control, so the
  common order is a couple of taps rather than a dozen — six drinks for the office is one
  pass, not six.
- A customer can follow their own order live (§9.2). Anyone holding a pickup code can watch
  their drinks move from waiting to being made to ready, one line per drink, with the wait
  estimate updating as the kitchen works — no refreshing, and no seeing anybody else's order.
  A five-drink order shows three done and two still going instead of one bar that sits at
  "in progress" for eight minutes.
- The kitchen display exists (§9.4). Baristas sign in with a station and PIN and get a single
  lane of drink cards — drink name, options as bold tokens, pickup code, and position within a
  multi-drink order so it is obvious when the scheduler is interleaving one. One tap starts a
  drink, one tap finishes it, no confirmation dialogs, and a 60-second undo is the escape
  hatch. A "Next up" section always shows the next three so cups and toppings can be
  pre-staged. The header carries queue depth and the oldest wait, and nothing else.
- The KDS sign-in response says which store the station belongs to, which the display needs
  in order to subscribe to live updates (§13.3).
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

### Changed
- **Simulated customers now see the same wait estimate the real shop would show them**
  (§7.1, §10.3). They were deciding whether to stay or leave based on an older, cruder
  calculation that the shop itself stopped using — one that quoted by queue position and so
  badly overstated the wait whenever fair queuing was about to serve a small order early.
  The result is that simulated runs show fewer people walking out at high demand, which is
  the more accurate figure rather than a rosier one.
- The kitchen interleaves orders more finely: a barista is handed roughly one drink per turn
  rather than one or two. Measured across 24 simulated days, this does not change how long
  anyone waits — it changes who absorbs the delay. Before, a few customers were badly
  delayed when a busy patch hit; now more customers are slightly delayed and almost nobody
  is badly delayed. The worst case at peak falls from over four minutes to under a minute
  and a half (§6.1, §10.5).
- The order status screen leads with how many drinks are made rather than with a countdown,
  and quotes the wait as a range. The estimate really does move — the kitchen shares capacity
  between orders, so drinks ordered after yours can push yours out — and a single number that
  jumps upward reads as a broken promise. A count of finished drinks only ever goes forward,
  which gives a customer one thing to trust while the estimate does what it honestly must
  (§7.3, §9.3).

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

### Fixed
- **The quantum sweep chart now marks what its lines are actually worth in seconds**
  (§10.5). It shipped with only the caption stating each series' range in words — reading
  a point's height meant hovering it one at a time. Both sweep charts now carry reference
  lines with values on them, so the shape of a curve is legible at a glance instead of only
  its endpoints.
- **Undoing a mistap on the kitchen display no longer teaches the board a drink was faster
  than it is** (§5.2, §7.3). Tapping Done on the wrong card and undoing it still counted
  that non-drink toward how long the drink takes — and because a mistap is nearly always
  *early*, every one of them dragged the learned time down and made the board quote short.
  One undone mistap was enough to move a 60-second drink to 52. The shop now waits out the
  60-second undo window before learning anything, so an undone tap teaches it nothing,
  and a drink that is finished, undone, and finished again counts once rather than twice.
  Drinks nobody touches are learned from exactly as before, a minute later.
- **An order placed for a later pickup time no longer says "ready now"** (§7.1, §7.3). A
  customer ordering at 9am for an 11am collection was quoted **zero seconds**, on their own
  screen and on the board, because the kitchen correctly refuses to start the drink yet and
  nothing filled in the answer. They are now quoted the time they actually chose. An
  identical order placed for right away was, and still is, quoted normally.
- A pre-ordered pickup time is no longer padded by the safety margin meant for estimates —
  someone who picked 11:00 was being told 11:18, and the error grew the further ahead they
  ordered.

- **A phone number that could never receive a text is refused at checkout** (§9.7). The
  field took anything at all, so a mistyped number produced an order that was made normally
  and a "your order is ready" text that went nowhere, with nothing to say so. Numbers are
  accepted the way people write them — `(555) 555-0123` is fine — and the customer is told
  while they can still fix it. Leaving it blank is still fine; the phone is optional.
- The cart bar's **Review** button now sits at the right of the bar instead of wherever the
  drink list happened to end.
- **A remade drink no longer makes an order look bigger than it is.** After a barista
  spilled one drink of a two-drink order, the kitchen display counted the spilled drink and
  showed the remaining cards as "2 of 3" and "3 of 3" — while the customer's own screen still
  said two drinks. Both now count only the drinks the order is still for (§9.4).
- Live order updates no longer get slower as the shop sells more. Every order the shop had
  ever taken was still counted as in progress, so the once-a-second push to customers'
  screens walked the whole history — 371ms at 2000 orders and growing, against 15ms now.
  It now pushes only to orders that are still being made or went ready in the last five
  minutes (ADR-0017).

- Pickup codes on the board line up in a column again instead of drifting with the length of
  the name beside them — a long enough first name pushed the code off the card entirely. The
  code is what tells two Sarahs apart (§9.5, locked), so it has to be scannable.
- The drink line on the board is legible for an order of more than one drink. It showed each
  drink's full build string, so a single drink with toppings filled the line and everything
  after it was cut off. It now names the drinks, counts repeats, and summarises a long order:
  `Classic Milk Tea ×6`, or `Thai Tea ×2 · Taro Milk Tea ×2 +11 more` (§9.5).
- Refreshing the kitchen display no longer signs the barista out. The shift now survives a
  reload — a browser restart, an OS update, a tablet that reloads a backgrounded tab — and
  still ends when the tab is closed or "sign out" is tapped, so a shared tablet never hands
  the next barista the last one's session (§13.3).
- The kitchen display's "oldest" clock now counts up second by second instead of sitting
  still between updates. In a quiet shop nothing was broadcast for up to 30 seconds at a
  time, so the one number that says "a drink is being forgotten" was the one number that
  stopped moving (§9.4).

- The customer board keeps updating when the background worker is down. Wait times are
  recomputed at most every 2 seconds and the board refreshes up to once a second (§7.2, §9.2)
  — but the board had been gated on the slower of the two, so a drink finishing shortly after
  another produced no update at all, and a stopped worker froze the board with nothing on
  screen to say so.
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


- Live kitchen updates would have failed in development and production with a gem loading
  error. The Redis client was pinned a major version ahead of what ActionCable accepts, so
  the pub/sub adapter §14.4 requires could not load — and the test suite could not see it,
  because tests use a different adapter. Caught by exercising the running container.

### Security
- **The public API throttles by IP** (§13.2): 10 orders/minute, 60 pickup-code lookups/minute,
  10 KDS PIN attempts/minute. A four-digit barista PIN is the one place brute force was
  genuinely cheap; a busy Saturday from the store's own kiosk is exempted by a `KIOSK_IPS`
  safelist rather than raising the limit for everyone. Counters live in Redis, not in-process
  memory — `web` runs 2 pods (§14.2), and a per-pod counter would silently double every limit.
- **The cluster is served over TLS, and only over TLS** (§14.5). The admin sign-in cookie is
  marked secure, which means a browser refuses to store it from a plain-http address — so
  signing in to the admin screens worked when scripted and silently did nothing in a real
  browser. The shop now answers at `https://boba.localtest.me:8443`; plain http is not
  served at all rather than served and quietly broken. Certificates are issued and renewed
  by the cluster itself.
