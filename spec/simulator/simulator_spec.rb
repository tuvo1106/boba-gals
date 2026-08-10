require "simulator_helper"

RSpec.describe Simulator do
  def run(**overrides)
    described_class.run(Simulator::Scenario.new(**overrides))
  end

  # §10.2: "Seed the RNG and surface the seed in the UI. Reproducible bad days
  # are the entire point." A run nobody can replay is an anecdote.
  describe "determinism" do
    it "returns identical metrics for the same seed" do
      expect(run(seed: 7).to_h).to eq(run(seed: 7).to_h)
    end

    it "returns different metrics for different seeds" do
      expect(run(seed: 7).to_h).not_to eq(run(seed: 8).to_h)
    end
  end

  # §10.2: "A 12-hour simulated day completes in well under a second, which is
  # what makes parameter sweeps (thousands of runs) practical."
  it "simulates a full day in well under a second" do
    elapsed = Benchmark.realtime { run(seed: 1) }

    expect(elapsed).to be < 0.5
  end

  describe "the generative model (§10.3)" do
    it "serves every order it generates" do
      metrics = run(seed: 3).to_h

      expect(metrics[:orders]).to be > 100
      expect(metrics[:drinks]).to be > metrics[:orders]
    end

    # "Order size must be heavy-tailed. The catering orders are the entire
    # reason DRR exists." A model without them tests nothing.
    it "produces catering-sized orders" do
      expect(run(seed: 3).to_h[:by_size_class]["7+"][:orders]).to be_positive
    end

    # "Prep time is right-skewed. Drinks occasionally go wrong; they never go
    # faster than possible. Lognormal, not normal."
    it "never samples a negative prep time" do
      rng = Simulator::Rng.new(99)
      samples = Array.new(5_000) { rng.lognormal(40, 0.28) }

      expect(samples.min).to be_positive
      expect(samples.max).to be > 40, "no right tail — the distribution is not skewed"
    end

    it "scales with the demand multiplier" do
      expect(run(seed: 5, demand_multiplier: 2.0).to_h[:orders])
        .to be > run(seed: 5, demand_multiplier: 1.0).to_h[:orders]
    end
  end

  # §10.1's one rule, asserted rather than assumed.
  # Common random numbers (§17). Without this the simulator cannot answer the
  # question it exists to answer: a policy change reorders `drink_finished`
  # events, which reorders every draw made from a shared generator, and the two
  # runs end up facing different demand. The delta you measure is then policy
  # plus a different random day, with no way to separate them.
  describe "common random numbers" do
    def index(policy, seed: 7)
      Simulator.simulate(Simulator::Scenario.new(seed: seed, stations: 3, scheduler_config: { "policy" => policy }))
               .completed.flat_map(&:items).to_h { |drink| [ drink.id, drink ] }
    end

    let(:drr) { index("drr") }
    let(:fifo) { index("fifo") }

    it "serves the same drinks under either policy" do
      expect(drr.keys).to match_array(fifo.keys)
    end

    it "gives a drink the same intrinsic prep time however it is scheduled" do
      differing = drr.keys.reject { |id| drr[id].actual_prep_seconds == fifo[id].actual_prep_seconds }

      expect(differing).to be_empty, "#{differing.size} drinks changed prep time between policies"
    end

    it "gives an order the same customer however it is scheduled" do
      %w[drr fifo].each_cons(2) do
        a = Simulator.simulate(Simulator::Scenario.new(seed: 7, scheduler_config: { "policy" => "drr" })).completed
        b = Simulator.simulate(Simulator::Scenario.new(seed: 7, scheduler_config: { "policy" => "fifo" })).completed
        by_id = b.to_h { |o| [ o.id, o ] }

        a.each { |order| expect(order.web).to eq(by_id[order.id].web) if by_id.key?(order.id) }
      end
    end

    # The part that must still differ: which station picks a drink up is a
    # scheduling outcome, not a property of the drink.
    it "still lets the schedule decide which station makes what" do
      moved = drr.keys.count { |id| drr[id].station != fifo[id].station }

      expect(moved).to be_positive
    end

    # A substream must be reproducible across processes. `String#hash` is
    # randomised per boot, so deriving from it would make a seed replayable only
    # within one run of the program — the opposite of §10.2's promise.
    it "derives a substream from the seed alone, not from process state" do
      key = Simulator::Rng.new(99).stream(:drink, "12-3")
      same = Simulator::Rng.new(99).stream(:drink, "12-3")
      other = Simulator::Rng.new(99).stream(:drink, "12-4")

      expect(Array.new(5) { key.uniform }).to eq(Array.new(5) { same.uniform })
      expect(Array.new(5) { key.uniform }).not_to eq(Array.new(5) { other.uniform })
    end

    it "keeps substreams independent of how much anything else has drawn" do
      quiet = Simulator::Rng.new(5)
      noisy = Simulator::Rng.new(5)

      100.times { noisy.stream(:drink, "noise").uniform }

      expect(Array.new(3) { noisy.stream(:pickup, 7).uniform })
        .to eq(Array.new(3) { quiet.stream(:pickup, 7).uniform })
    end
  end

  describe "the one rule (§10.1)" do
    it "dispatches through Scheduler.pick_next" do
      expect(Scheduler).to receive(:pick_next).at_least(20).times.and_call_original

      run(seed: 2, hours: 2)
    end

    it "honours the scheduler config it is given" do
      expect(run(seed: 4, scheduler_config: { policy: :fifo }).to_h[:orders]).to be_positive
    end
  end

  # The design's central claim, measured rather than asserted (§10.4). Load is
  # held constant across the comparison — sweeping the large-order rate without
  # compensating demand changes utilisation, and then the result is about
  # saturation rather than scheduling.
  describe "the fairness claim (§10.4)" do
    def mean_size(rate)
      Simulator::Scenario.new(large_order_rate: rate).size_mix
                         .sum { |k, p| (k.is_a?(Range) ? (k.min + k.max) / 2.0 : k) * p }
    end

    def small_order_p90(policy:, large_rate:, seeds: 6)
      multiplier = mean_size(0.0) / mean_size(large_rate)

      values = (1..seeds).map do |seed|
        described_class.run(Simulator::Scenario.new(
          seed: seed, large_order_rate: large_rate, demand_multiplier: multiplier,
          scheduler_config: { policy: policy }
        )).small_order_p90
      end

      values.sum / values.size
    end

    it "keeps small orders waiting far less under DRR than under FIFO" do
      drr = small_order_p90(policy: :drr, large_rate: 0.12)
      fifo = small_order_p90(policy: :fifo, large_rate: 0.12)

      expect(drr).to be < fifo * 0.75,
        "DRR #{drr.round}s vs FIFO #{fifo.round}s — fair queuing is not earning its keep"
    end

    # "The same test under FIFO shows a clearly rising line. If it doesn't, the
    # generative model isn't stressing the system — fix the model, don't relax
    # the assertion." (§10.4)
    it "shows a clearly rising line under FIFO" do
      flat = small_order_p90(policy: :fifo, large_rate: 0.0)
      loaded = small_order_p90(policy: :fifo, large_rate: 0.12)

      expect(loaded).to be > flat * 1.5,
        "FIFO barely moved — the generative model is not stressing the system"
    end

    it "rises far less steeply under DRR than under FIFO" do
      drr = small_order_p90(policy: :drr, large_rate: 0.12) / small_order_p90(policy: :drr, large_rate: 0.0)
      fifo = small_order_p90(policy: :fifo, large_rate: 0.12) / small_order_p90(policy: :fifo, large_rate: 0.0)

      expect(drr).to be < fifo
    end
  end

  # A simulator that silently drops work reports metrics over a subset, and the
  # subset it drops is the slow tail — so the numbers look better than the shop.
  describe "conservation" do
    it "accounts for every order that arrives" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 3))

      expect(world.completed.size + world.reneged).to eq(world.arrived),
        "#{world.arrived - world.completed.size - world.reneged} orders vanished"
    end

    it "drains the event queue rather than stopping with work outstanding" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 3))

      expect(world.instance_variable_get(:@pending)).to be_empty
    end

    it "finishes every drink of every completed order" do
      orders = described_class.simulate(Simulator::Scenario.new(seed: 3)).completed

      expect(orders).to all(satisfy { |o| o.items.all?(&:finished_at) })
      expect(orders).to all(satisfy { |o| o.ready_at >= o.arrived_at })
    end
  end

  # The four processes the station-availability loop had nowhere to put. Each is
  # listed in §10.3 and each was missing until the event queue landed.
  describe "the processes the event queue enables (§10.2, §10.3)" do
    it "fails roughly remake_rate of drinks and re-queues them" do
      h = run(seed: 42).to_h

      expect(h[:remakes]).to be_positive
      expect(h[:remakes].to_f / h[:drinks]).to be_within(0.015).of(0.02)
    end

    # A remake is a new drink on the same order (§5.2), which is what gives the
    # order a pending remake and therefore §6.4's priority floor. Nothing else
    # in the model reaches that code path.
    it "puts the remake on the original order rather than a new one" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))
      remade = world.completed.select { |o| o.items.any?(&:remake?) }

      expect(remade).to be_any
      expect(remade).to all(satisfy { |o| o.items.count > o.items.count(&:remake?) })
    end

    it "collects every completed order, after a delay" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))

      expect(world.completed).to all(satisfy(&:picked_up_at))
      expect(world.completed).to all(satisfy { |o| o.picked_up_at > o.ready_at })
    end

    # §9.6's quality timer needs pickup to exist before it can measure anything.
    it "reports a quality breach rate" do
      expect(run(seed: 42).to_h[:quality_breach_rate]).to be_between(0, 1)
    end

    # §9.6 is explicit that the quality timer is *per drink*. Measuring it per
    # order — from the earliest drink's finish — scores a 20-drink order where
    # nineteen drinks went stale as a single breach, which is precisely the
    # failure the cohesion boost exists to prevent.
    it "counts one breach per stale drink, not one per stale order" do
      order = Simulator::Order.new(
        id: 1, arrived_at: 0, items: [
          Simulator::Drink.new(id: "1-0", prep_seconds: 60, service_seconds: 60, finished_at: 0),
          Simulator::Drink.new(id: "1-1", prep_seconds: 60, service_seconds: 60, finished_at: 10),
          Simulator::Drink.new(id: "1-2", prep_seconds: 60, service_seconds: 60, finished_at: 590)
        ],
        first_ready_at: 0, ready_at: 590, picked_up_at: 600
      )

      # Two drinks sat 600s and 590s; the last sat 10s.
      expect(order.sat_seconds).to eq([ 600, 590, 10 ])
      expect(described_class::Metrics.new(orders: [ order ], seconds: 600, stations: 1)
               .to_h[:quality_breach_rate]).to eq((2.0 / 3).round(3))
    end

    # A single-drink order's sitting time *is* the customer's walk-up delay, so
    # it can never be improved by scheduling. Reporting it mixed into one figure
    # puts a floor near 10% under the number and hides the cohesion signal.
    it "reports multi-drink orders separately from the pickup-delay floor" do
      metrics = run(seed: 7, stations: 1, demand_multiplier: 3.0).to_h

      expect(metrics[:quality_breach_rate_multi]).to be > metrics[:quality_breach_rate]
    end

    it "generates order-ahead orders, which exercise backward scheduling" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 42))

      expect(world.completed.count(&:promised_at)).to be_positive
    end

    # "Reneging prices the cost of slowness in lost revenue rather than abstract
    # seconds." It must be quiet in a healthy shop and bite in a saturated one —
    # a renege model that fires at low load would understate every wait.
    # Negligible, not zero. §10.3's renege probability is a soft ramp above an
    # 8-minute quoted wait, and a shop averaging 36% utilisation still crosses
    # that in bursts — at seed 7, 9 of 142 web arrivals are quoted over 480s and
    # one of them leaves. Asserting exactly zero pins the test to one alignment
    # of the random streams rather than to anything the model claims.
    it "barely reneges in a shop that is keeping up" do
      calm = run(seed: 7, demand_multiplier: 1.0).to_h

      expect(calm[:station_utilisation]).to be < 0.5
      expect(calm[:reneged].to_f / calm[:orders]).to be < 0.01
    end

    it "reneges sharply once the shop saturates" do
      calm = run(seed: 7, demand_multiplier: 1.0).to_h
      swamped = run(seed: 7, demand_multiplier: 2.5).to_h

      expect(swamped[:station_utilisation]).to be > 0.85
      expect(swamped[:reneged]).to be > calm[:reneged] + 50
    end
  end

  describe "the event queue (§10.2)" do
    it "pops events in time order" do
      q = Simulator::EventQueue.new
      [ 5.0, 1.0, 3.0, 2.0, 4.0 ].each { |t| q.push(t, :order_arrives) }

      expect(Array.new(5) { q.pop.at }).to eq([ 1.0, 2.0, 3.0, 4.0, 5.0 ])
    end

    # Reproducibility from a seed requires ties to break deterministically;
    # otherwise heap layout, which depends on insertion history, decides.
    it "breaks ties on insertion order" do
      q = Simulator::EventQueue.new
      %i[first second third].each { |name| q.push(1.0, name) }

      expect(Array.new(3) { q.pop.type }).to eq(%i[first second third])
    end

    it "is empty when drained" do
      q = Simulator::EventQueue.new.push(1.0, :pickup)

      expect(q.pop).not_to be_nil
      expect(q).to be_empty
      expect(q.pop).to be_nil
    end
  end

  # Conservation proves nothing is dropped. It cannot catch a simulator that
  # counts consistently but computes time wrongly — for that you need an
  # identity the model must satisfy regardless of its distributions.
  #
  # Little's Law (§17) is that identity: L = λW. The time-average number of
  # orders in the shop equals the arrival rate times the average time each
  # spends there. It holds for *any* arrival process and *any* service
  # distribution, so it tests the bookkeeping without assuming the model.
  describe "Little's Law (§17)" do
    def little(demand, seeds: 6)
      (1..seeds).map do |seed|
        world = described_class.simulate(Simulator::Scenario.new(seed: seed, demand_multiplier: demand))
        orders_in_shop = world.order_seconds / world.clock
        arrival_rate = world.completed.size / world.clock
        time_in_shop = world.completed.sum(&:wait_seconds) / world.completed.size

        [ orders_in_shop, arrival_rate * time_in_shop ]
      end
    end

    # Looser at low demand: the day starts and ends empty, and the identity
    # assumes steady state, so that transient is a larger share of a quiet day.
    it "holds at ordinary demand" do
      measured, predicted = little(1.0).transpose.map { |v| v.sum / v.size }

      expect(measured).to be_within(measured * 0.10).of(predicted)
    end

    it "holds tightly once the shop is busy enough to reach steady state" do
      measured, predicted = little(2.5).transpose.map { |v| v.sum / v.size }

      expect(measured).to be_within(measured * 0.03).of(predicted)
    end

    # A necessary condition, not a sufficient one: a simulator with the wrong
    # service times would still satisfy it. What it rules out is orders being
    # double-counted, dropped, or timed against the wrong clock.
    it "integrates the order count exactly rather than sampling it" do
      world = described_class.simulate(Simulator::Scenario.new(seed: 1))

      expect(world.order_seconds).to be_positive
      expect(world.order_seconds / world.clock).to be < world.completed.size
    end
  end

  # The ribbon only ever shows a slice of the day, so finding a given order needs
  # an index the client can search without re-running the simulation (§10.6).
  # §10.4 reports by the size of the order the *customer placed*. `items` grows
  # when a drink is remade (§5.2), so counting it moves a remade 2-drink order
  # into the "3-6" class — and remade orders are the slow ones, carrying extra
  # work and §6.4's priority floor, so dropping them out of "1-2" makes the
  # headline number look better than it is.
  describe "size classes (§10.4)" do
    def order_with(ordered:, remakes:)
      items = Array.new(ordered) { |i| Simulator::Drink.new(id: "1-#{i}", prep_seconds: 60, service_seconds: 60, finished_at: 60) } +
              Array.new(remakes) { |i| Simulator::Drink.new(id: "1-#{i}r", prep_seconds: 60, service_seconds: 60, finished_at: 60, remake: true) }

      Simulator::Order.new(id: 1, arrived_at: 0, ready_at: 600, items: items)
    end

    it "counts the drinks ordered, not the drinks made" do
      remade = order_with(ordered: 2, remakes: 1)

      expect(remade.items.size).to eq(3)
      expect(remade.ordered_size).to eq(2)

      classes = described_class::Metrics.new(orders: [ remade ], seconds: 600, stations: 1).to_h[:by_size_class]

      expect(classes["1-2"][:orders]).to eq(1)
      expect(classes["3-6"][:orders]).to eq(0)
    end

    it "keeps the headline number honest across a real run" do
      w = described_class.simulate(Simulator::Scenario.new(seed: 7, stations: 3, demand_multiplier: 2.0))
      reclassified = w.completed.count { |o| o.items.size != o.ordered_size }

      expect(reclassified).to be_positive, "no remakes in this run — the guard would prove nothing"
      expect(described_class::Metrics.new(orders: w.completed, seconds: w.clock, stations: 3)
               .to_h[:by_size_class]["1-2"][:orders])
        .to eq(w.completed.count { |o| o.ordered_size <= 2 })
    end
  end

  # "Does your wait depend on what you ordered?" — the sharpest single number
  # for what equalising barista *time* buys, and the only figure that separates
  # the arms at default demand, where every p90 is within noise (§10.3).
  describe "the drink-cost penalty (§6.1)" do
    def penalty(policy, demand: 2.0, seed: 7)
      w = described_class.simulate(Simulator::Scenario.new(seed: seed, stations: 3, demand_multiplier: demand,
                                                          scheduler_config: { "policy" => policy }))
      described_class::Metrics.new(orders: w.completed, seconds: w.clock, stations: 3).to_h[:wait_by_drink_cost]
    end

    # The headline. SJF defers whatever is expensive, and a small order holding
    # one Brown Sugar Pearl has no cheap drink to hide behind.
    it "is far worse under SJF than under DRR" do
      expect(penalty("sjf")[:ratio]).to be > penalty("drr")[:ratio] * 3
    end

    it "separates the arms even at the default demand where every p90 agrees" do
      expect(penalty("sjf", demand: 1.0)[:ratio]).to be > penalty("drr", demand: 1.0)[:ratio]
    end

    # Zero is not a good score. Without a `comparable` flag an empty run reports
    # 0.00x, which the dashboard paints green — the same failure as a p90 over
    # five orders reading as a percentile.
    it "does not report a perfect score when there is nothing to compare" do
      empty = described_class::Metrics.new(orders: [], seconds: 100, stations: 3).to_h[:wait_by_drink_cost]

      expect(empty[:ratio]).to be_zero
      expect(empty[:comparable]).to be(false)
    end

    it "is comparable once both sides have enough orders" do
      expect(penalty("drr")[:comparable]).to be(true)
    end

    # Queueing, not wait. A 95s drink takes 95s under any policy, so including
    # its own prep would report the menu spread as unfairness in an empty shop.
    it "excludes the work the order itself brought" do
      order = Simulator::Order.new(
        id: 1, arrived_at: 0, ready_at: 300,
        items: [ Simulator::Drink.new(id: "1-0", prep_seconds: 95, service_seconds: 95, finished_at: 300) ]
      )

      expect(order.wait_seconds).to eq(300)
      expect(order.queue_seconds).to eq(205)
    end

    # Two drinks on two idle stations finish together, so the least the order
    # could take is its slowest drink — subtracting the sum would go negative.
    it "measures the critical path rather than total work" do
      order = Simulator::Order.new(
        id: 1, arrived_at: 0, ready_at: 95,
        items: [ Simulator::Drink.new(id: "1-0", prep_seconds: 95, service_seconds: 95, finished_at: 95),
                 Simulator::Drink.new(id: "1-1", prep_seconds: 40, service_seconds: 40, finished_at: 40) ]
      )

      expect(order.queue_seconds).to eq(0)
    end
  end

  describe "#order_spans" do
    let(:world) { described_class.simulate(Simulator::Scenario.new(seed: 3, stations: 3)) }
    let(:pending) { world.instance_variable_get(:@pending) }

    it "spans every order that had a drink dispatched" do
      dispatched = (world.completed + pending).count { |o| o.items.any?(&:started_at) }

      expect(world.order_spans.size).to eq(dispatched)
    end

    it "brackets each order's drinks between its first start and last finish" do
      by_id = world.completed.to_h { |o| [ o.id, o ] }

      world.order_spans.each do |id, from, to, size|
        order = by_id[id]
        next if order.nil?

        expect(size).to eq(order.items.size)
        expect(from).to be_within(0.01).of(order.items.filter_map(&:started_at).min)
        expect(to).to be_within(0.01).of(order.items.filter_map(&:finished_at).max)
      end
    end

    # By start time rather than id: an order-ahead order (§10.3) is dispatched
    # hours after it arrives, so the two orderings genuinely differ.
    it "is ordered by start time, not by order id" do
      starts = world.order_spans.map { |span| span[1] }
      ids = world.order_spans.map(&:first)

      expect(starts).to eq(starts.sort)
      expect(ids).not_to eq(ids.sort)
    end

    it "omits orders whose drinks never started" do
      never_started = pending.reject { |o| o.items.any?(&:started_at) }.map(&:id)

      expect(world.order_spans.map(&:first)).not_to include(*never_started) if never_started.any?
      expect(world.order_spans.map(&:first)).to all(be_positive)
    end
  end

  describe "metrics (§10.4)" do
    it "reports percentiles, never a mean" do
      expect(run(seed: 1).to_h[:wait_seconds].keys).to eq(%i[p50 p90 p99])
    end

    it "orders percentiles" do
      w = run(seed: 1).to_h[:wait_seconds]

      expect(w[:p50]).to be <= w[:p90]
      expect(w[:p90]).to be <= w[:p99]
    end

    it "reports waits by size class, so one cannot hide behind another" do
      expect(run(seed: 1).to_h[:by_size_class].keys).to eq([ "1-2", "3-6", "7+" ])
    end

    it "reports utilisation, which is where staffing decisions get made" do
      expect(run(seed: 1).to_h[:station_utilisation]).to be_between(0, 1)
    end

    # Understating utilisation understates how close the shop is to saturation,
    # which is the number §10.4 says staffing decisions are made on.
    it "measures utilisation from time stations were actually occupied" do
      drinks = described_class.simulate(Simulator::Scenario.new(seed: 1)).completed.flat_map(&:items)

      # Skill is U(0.85, 1.20) and fatigue multiplies, so service time differs
      # from raw prep time on essentially every drink.
      expect(drinks.count { |d| d.service_seconds != d.actual_prep_seconds }).to eq(drinks.size)
      expect(drinks).to all(satisfy { |d| (d.finished_at - d.started_at - d.service_seconds).abs < 0.001 })
    end

    it "reports cohesion spread, the melted-first-drink measure" do
      expect(run(seed: 1).to_h[:cohesion_spread_p90]).to be >= 0
    end

    it "is empty rather than broken for a shop with no arrivals" do
      expect(run(seed: 1, arrival_profile: [ 0 ]).to_h[:orders]).to eq(0)
    end
  end

  # §10.4: "ETA error (p50 abs) **and bias** (signed mean) — bias is the one
  # that destroys trust." §7.3 puts it as the difference between a board
  # customers trust and one they learn to ignore.
  describe "ETA accuracy (§10.4, §7.3)" do
    def accuracy(**overrides) = run(seed: 7, stations: 3, **overrides).to_h[:eta_accuracy]

    it "reports absolute error and signed bias, because they answer different questions" do
      expect(accuracy).to include(:p50_abs, :p90_abs, :bias, :orders, :capped, :measurable)
    end

    # The one place this suite wants a mean. A shop that beats its quote on half
    # of orders and is four minutes late on the other half has a median signed
    # error near zero and a trust problem — only the mean sees it.
    it "signs the bias, so a shop that is always late cannot hide behind a median" do
      late = [ order_quoted(60, took: 300), order_quoted(60, took: 300) ]

      expect(metrics_for(late)[:bias]).to be > 200
    end

    it "reads negative when the shop beats its quote" do
      early = [ order_quoted(300, took: 60), order_quoted(300, took: 60) ]

      expect(metrics_for(early)[:bias]).to be_negative
    end

    # An estimator this far off would be reported as unbiased by absolute error
    # alone, which is exactly the failure §10.4 pairs the two figures to catch.
    it "keeps absolute error positive when the bias cancels to zero" do
      mixed = [ order_quoted(60, took: 300), order_quoted(300, took: 60) ]
      result = metrics_for(mixed)

      expect(result[:bias]).to be_within(1).of(0)
      expect(result[:p50_abs]).to be > 200
    end

    # §7.1's projection against §10.3's shop. Not asserting a tight bound — the
    # point is that the estimator is not systematically wrong by more than a
    # drink's worth of time in a shop that is keeping up.
    it "is close to unbiased in a shop that is keeping up" do
      result = accuracy(demand_multiplier: 1.0)

      expect(result[:measurable]).to be(true)
      expect(result[:bias].abs).to be < 60
    end

    # This figure was +142s until `ProjectEta#order_ahead`'s defect was fixed in
    # both projections: an order-ahead customer was quoted zero and then
    # "waited" their entire two-hour horizon. Nothing else moved it.
    it "does not let order-ahead customers manufacture a bias" do
      with_ahead = accuracy(demand_multiplier: 1.0, order_ahead_share: 0.5)

      expect(with_ahead[:bias].abs).to be < 120
    end

    # A capped quote is a floor, so its error is an artefact of the cap. Counted
    # rather than dropped silently — a run where most orders are capped is a
    # saturated shop, and the accuracy figures then describe only the minority
    # who got a real answer.
    # An earlier version of this asserted only that `capped` was positive in a
    # saturated run, which stayed true whether or not the exclusion existed —
    # removing the exclusion left every example green. It measured that the
    # counter counted, not that the figures ignored what it counted.
    it "leaves a capped quote out of the error figures entirely" do
      usable = order_quoted(60, took: 90)
      capped = order_quoted(60, took: 3000)
      capped.quote_capped = true

      result = metrics_for([ usable, capped ])

      expect(result[:orders]).to eq(1)
      expect(result[:capped]).to eq(1)
      # Counted, the capped order's 2940s miss would set p50_abs on its own.
      expect(result[:p50_abs]).to eq(30.0)
    end

    it "reaches the horizon at all in a shop far past saturation" do
      expect(accuracy(demand_multiplier: 3.5)[:capped]).to be_positive
    end

    it "refuses to call a handful of orders a percentile" do
      expect(metrics_for([ order_quoted(60, took: 90) ])[:measurable]).to be(false)
    end

    it "is zero rather than broken for a shop with no arrivals" do
      expect(run(seed: 1, arrival_profile: [ 0 ]).to_h[:eta_accuracy][:orders]).to eq(0)
    end

    def order_quoted(quoted, took:)
      Simulator::Order.new(
        id: rand(1_000_000), arrived_at: 0.0, ready_at: took.to_f, quoted_seconds: quoted.to_f,
        items: [ Simulator::Drink.new(id: "d", prep_seconds: 60, actual_prep_seconds: 60,
                                      service_seconds: 60.0, finished_at: took.to_f, remake: false) ]
      )
    end

    def metrics_for(orders)
      described_class::Metrics.new(orders: orders, seconds: 3600, stations: 1).to_h[:eta_accuracy]
    end
  end
end
