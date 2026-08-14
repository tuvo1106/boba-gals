require_relative "spec_helper"

# The §11 checklist. Every case below is required before DRR ships — CLAUDE.md
# says not to merge the scheduler with any of them missing.
#
# These are the specs the design's central claim rests on: *a large order must
# not block small orders*. A green suite here is the difference between that
# being an assertion and being a property.
RSpec.describe DeficitScheduler do
  describe "the fairness claim (§2, §11)" do
    # The headline case. Under FIFO the single drink waits behind fifteen
    # others — roughly fifteen minutes. Under DRR it waits about one drink.
    it "dispatches a single drink arriving behind a 15-drink order within one quantum" do
      catering = flow(id: :catering, items: 15, arrived_at: at(0))
      single = flow(id: :single, items: 1, arrived_at: at(10))
      s = state([ catering, single ])

      sequence = dispatch_all(s, now: at(10))
      position = sequence.index(:single)

      expect(position).not_to be_nil, "the single drink was never dispatched"
      expect(position).to be < 3,
        "waited behind #{position} drinks — DRR should interleave it almost immediately"
    end

    # The other direction, and the one a naive priority scheme gets wrong: small
    # orders must not starve the large one either.
    it "still completes a 20-drink order under a continuous stream of single drinks" do
      large = flow(id: :large, items: 20, arrived_at: at(0))
      smalls = Array.new(40) { |i| flow(id: :"small_#{i}", items: 1, arrived_at: at(i * 5)) }
      s = state([ large, *smalls ])

      sequence = dispatch_all(s, now: at(200))

      expect(sequence.count(:large)).to eq(20), "the large order starved"
      expect(sequence.size).to eq(60)
    end

    it "interleaves rather than draining one order at a time" do
      a = flow(id: :a, items: 6, arrived_at: at(0))
      b = flow(id: :b, items: 6, arrived_at: at(0))
      s = state([ a, b ])

      sequence = dispatch_all(s, now: at(0))

      # Six of each; if it drained one order first the first six would be all :a.
      expect(sequence.first(6).uniq.size).to eq(2)
    end
  end

  describe "remakes (§6.4)" do
    it "puts a remake ahead of same-age normal work" do
      normal = flow(id: :normal, items: 1, arrived_at: at(0))
      remade = flow(id: :remade, items: 1, arrived_at: at(0), expedited: true)
      s = state([ normal, remade ])

      expect(dispatch_all(s, now: at(0)).first).to eq(:remade)
    end

    # The reason §6.4 chose a floor over a fixed bump: two remakes must still
    # compete with each other by age.
    it "puts an older remake ahead of a newer one" do
      newer = flow(id: :newer, items: 1, arrived_at: at(600), expedited: true)
      older = flow(id: :older, items: 1, arrived_at: at(0), expedited: true)
      s = state([ newer, older ])

      expect(dispatch_all(s, now: at(600)).first).to eq(:older)
    end

    # Kills the `any?` → `all?` mutant. A remade drink joins an order that still
    # has ordinary drinks in it, so a flow is almost never all-remake — reading
    # `all?` would quietly withdraw the floor from every real remake.
    it "gives the floor to an order carrying one remake among ordinary drinks" do
      mixed = DeficitScheduler::Flow.new(
        id: :mixed, arrived_at: at(0),
        queue: [ item(enqueued_at: at(0)), item(enqueued_at: at(0), expedited: true) ]
      )
      normal = flow(id: :normal, items: 2, arrived_at: at(0))

      expect(dispatch_all(state([ normal, mixed ]), now: at(0)).first).to eq(:mixed)
    end

    # A fixed additive bump gets swamped: after 20 minutes of aging a normal
    # order's multiplier would exceed a fresh remake's. The floor must hold.
    it "keeps a fresh remake ahead of a long-aged normal order" do
      aged = flow(id: :aged, items: 1, arrived_at: at(0))
      fresh_remake = flow(id: :fresh_remake, items: 1, arrived_at: at(1800), expedited: true)
      s = state([ aged, fresh_remake ])

      expect(dispatch_all(s, now: at(1800)).first).to eq(:fresh_remake)
    end
  end

  # Off by default since ADR-0014 measured the original fraction_made trigger
  # making spread worse, so these enable it explicitly. Re-triggered on how
  # long the earliest finished drink has actually sat, shaped like aging below
  # (#31, ADR-0032) — kept and still asserted so the knob keeps working for
  # whichever finding the re-trigger produces.
  describe "cohesion (§6.4, §9.6), enabled explicitly" do
    # §6.4's motivating case: a multi-drink order whose first drink is already
    # sitting grows its quantum the longer that drink waits.
    it "boosts a multi-drink order the longer its first drink has sat" do
      pair = flow(id: :pair, items: 1, total_items: 2, arrived_at: at(0), first_output_at: at(0))
      config = DeficitScheduler::Config.new(aging_enabled: false, staleness_enabled: true, staleness_boost: 0.2)

      # 5 minutes × 0.2/min = +1.0 → 2.0 quanta
      expect(described_class.quantum_for(pair, at(300), config)).to eq(config.quantum * 2.0)
    end

    it "does not boost while nothing in the order has finished yet" do
      untouched = flow(id: :untouched, items: 2, total_items: 2, arrived_at: at(0), first_output_at: nil)
      config = DeficitScheduler::Config.new(aging_enabled: false, staleness_enabled: true, staleness_boost: 0.2)

      expect(described_class.quantum_for(untouched, at(300), config)).to eq(config.quantum)
    end

    # A single-drink order reaches `ready` the same instant it reaches
    # `first_ready_at` in production and the simulator, leaving the flow set
    # before the next rebuild — but nothing here guarantees a caller obeys
    # that, so this stays a real, reachable guard rather than an assumption.
    it "does not boost a single-drink order even with first_ready_at set" do
      single = flow(id: :single, items: 1, total_items: 1, arrived_at: at(0), first_output_at: at(0))
      config = DeficitScheduler::Config.new(aging_enabled: false, staleness_enabled: true, staleness_boost: 0.2)

      expect(described_class.quantum_for(single, at(300), config)).to eq(config.quantum)
    end

    it "can be switched off" do
      pair = flow(id: :pair, items: 1, total_items: 2, arrived_at: at(0), first_output_at: at(0))
      config = DeficitScheduler::Config.new(staleness_enabled: false, aging_enabled: false, staleness_boost: 0.2)

      expect(described_class.quantum_for(pair, at(300), config)).to eq(config.quantum)
    end

    # Not reachable via §6.5's flow-building (a drink cannot finish before its
    # order arrives), but the same clock-skew possibility aging guards against
    # (issue #49) applies here too.
    it "clamps sitting time at zero for a first_ready_at somehow after now" do
      pair = flow(id: :pair, items: 1, total_items: 2, arrived_at: at(0), first_output_at: at(100))
      config = DeficitScheduler::Config.new(aging_enabled: false, staleness_enabled: true, staleness_boost: 0.2)

      expect(described_class.quantum_for(pair, at(0), config)).to eq(config.quantum)
    end

    it "puts a flow whose first drink has sat longer ahead of an equal-age flow with nothing finished" do
      sitting = flow(id: :sitting, items: 1, total_items: 2, arrived_at: at(0), first_output_at: at(0))
      untouched = flow(id: :untouched, items: 2, total_items: 2, arrived_at: at(0), first_output_at: nil)
      s = state([ untouched, sitting ], staleness_enabled: true, staleness_boost: 0.2)

      expect(dispatch_all(s, now: at(300)).first).to eq(:sitting)
    end
  end

  describe "aging (§6.2)" do
    it "grows the quantum with waiting time so nothing starves" do
      waited = flow(id: :waited, arrived_at: at(0))
      config = DeficitScheduler::Config.new(staleness_enabled: false)

      # 10 minutes × 0.15/min = +1.5 → 2.5 quanta
      expect(described_class.quantum_for(waited, at(600), config)).to eq(config.quantum * 2.5)
    end

    it "can be switched off" do
      waited = flow(id: :waited, arrived_at: at(0))
      config = DeficitScheduler::Config.new(aging_enabled: false, staleness_enabled: false)

      expect(described_class.quantum_for(waited, at(600), config)).to eq(config.quantum)
    end

    # Not reachable via §6.5's flow-building (a drink cannot be queued before
    # its order exists), but clock skew between the two `web` pods (§14.2,
    # §14.4) could make `now` a few hundred ms earlier than `arrived_at`
    # (issue #49). Unclamped, this went negative and shrank the deficit on
    # every visit instead of growing it, eventually tripping LIVELOCK_GUARD.
    it "clamps waiting time at zero for a flow that has not arrived yet" do
      not_arrived = flow(id: :not_arrived, arrived_at: at(100))
      config = DeficitScheduler::Config.new(staleness_enabled: false)

      expect(described_class.quantum_for(not_arrived, at(0), config)).to eq(config.quantum)
    end
  end

  describe "order-ahead eligibility (§6.2)" do
    it "will not start an order promised two hours out" do
      later = flow(id: :later, items: 1, arrived_at: at(0), deadline: at(7200))
      s = state([ later ])

      expect(described_class.pick_next(s, at(0))).to be_nil
    end

    # Backward-scheduled start = promised_at − remaining work − promise_buffer.
    # One 60s drink with the default 120s buffer means 180s before the promise.
    it "becomes eligible at its backward-scheduled start, not before" do
      later = flow(id: :later, items: 1, cost: 60, arrived_at: at(0), deadline: at(1000))
      config = DeficitScheduler::Config.new

      expect(described_class.eligible?(later, at(819), config)).to be(false)
      expect(described_class.eligible?(later, at(820), config)).to be(true)
    end

    # Kills the `>=` → `==` mutant: testing only the boundary instant leaves a
    # scheduler that is eligible for exactly one second and never again.
    it "stays eligible once its start has passed" do
      later = flow(id: :later, items: 1, cost: 60, arrived_at: at(0), deadline: at(1000))

      expect(described_class.eligible?(later, at(900), DeficitScheduler::Config.new)).to be(true)
    end

    it "treats an ASAP order as always eligible" do
      asap = flow(id: :asap, items: 1, arrived_at: at(0))

      expect(described_class.eligible?(asap, at(0), DeficitScheduler::Config.new)).to be(true)
    end

    it "skips a not-yet-due order without blocking the ones behind it" do
      later = flow(id: :later, items: 1, arrived_at: at(0), deadline: at(7200))
      asap = flow(id: :asap, items: 1, arrived_at: at(0))
      s = state([ later, asap ])

      expect(dispatch_all(s, now: at(0))).to eq([ :asap ])
    end
  end

  describe "nothing to do" do
    it "returns nil for no flows at all, and never raises" do
      expect { described_class.pick_next(state([]), at(0)) }.not_to raise_error
      expect(described_class.pick_next(state([]), at(0))).to be_nil
    end

    it "returns nil when every flow has an empty queue" do
      drained = flow(id: :drained, items: 0)

      expect(described_class.pick_next(state([ drained ]), at(0))).to be_nil
    end
  end

  describe "the livelock guard (§6.2)" do
    # The guard exists because a bug in the ring would otherwise spin forever
    # with the kitchen silently stalled. It must raise, not return nil — a nil
    # would look exactly like an empty queue to the caller.
    it "raises rather than spinning when a flow can never afford its head" do
      # A zero quantum means the deficit never grows, so the flow is dispatchable
      # but can never pay for its drink. Only the guard breaks the loop.
      stuck = flow(id: :stuck, items: 1, cost: 60, arrived_at: at(0))
      s = state([ stuck ], quantum: 0, aging_enabled: false, staleness_enabled: false)

      expect { described_class.pick_next(s, at(0)) }
        .to raise_error(DeficitScheduler::LivelockError, /livelock/)
    end

    # The negative-quantum failure mode issue #49 describes: without the
    # aging clamp, a flow that has not "arrived" yet by the clock reading
    # passed in earns a negative quantum every visit, its deficit only ever
    # shrinks, and it can never afford its head drink — tripping this same
    # guard instead of dispatching normally. Clock skew between the two `web`
    # pods (§14.2, §14.4) is the one way `now` could precede `arrived_at` in
    # production.
    it "does not livelock a flow whose arrival is a second ahead of now" do
      skewed = flow(id: :skewed, items: 1, arrived_at: at(1))
      head = skewed.queue.first
      s = state([ skewed ])

      expect(described_class.pick_next(s, at(0))).to eq(flow: skewed, item: head)
    end
  end

  describe "the FIFO control arm (§6.3)" do
    it "dispatches in strict enqueued_at, id order" do
      first = flow(id: :first, items: 1, arrived_at: at(0))
      second = flow(id: :second, items: 1, arrived_at: at(10))
      third = flow(id: :third, items: 1, arrived_at: at(20))
      s = state([ third, first, second ], policy: :fifo)

      expect(dispatch_all(s, now: at(100))).to eq([ :first, :second, :third ])
    end

    # The point of keeping FIFO: it is the control arm, so it must *not* do any
    # of the things DRR does. A remake gets no floor here.
    it "ignores remakes, aging, and cohesion entirely" do
      normal = flow(id: :normal, items: 1, arrived_at: at(0))
      remade = flow(id: :remade, items: 1, arrived_at: at(10), expedited: true)
      s = state([ normal, remade ], policy: :fifo)

      expect(dispatch_all(s, now: at(100))).to eq([ :normal, :remade ])
    end

    # Kills the `[enqueued_at, id]` → `[nil, id]` mutant: with ids ordered
    # against arrival, only a real enqueued_at comparison gets this right.
    it "orders by enqueued_at even when item ids disagree" do
      early = DeficitScheduler::Flow.new(id: :early, arrived_at: at(0),
                                  queue: [ item(id: 99, enqueued_at: at(0)) ])
      late = DeficitScheduler::Flow.new(id: :late, arrived_at: at(0),
                                 queue: [ item(id: 1, enqueued_at: at(500)) ])

      expect(dispatch_all(state([ late, early ], policy: :fifo), now: at(500)))
        .to eq([ :early, :late ])
    end

    it "breaks ties on item id so the sequence is deterministic" do
      a = DeficitScheduler::Flow.new(id: :a, arrived_at: at(0),
                              queue: [ item(id: 2, enqueued_at: at(0)) ])
      b = DeficitScheduler::Flow.new(id: :b, arrived_at: at(0),
                              queue: [ item(id: 1, enqueued_at: at(0)) ])

      expect(dispatch_all(state([ a, b ], policy: :fifo), now: at(0))).to eq([ :b, :a ])
    end

    it "returns nil when nothing is dispatchable" do
      expect(described_class.pick_next(state([], policy: :fifo), at(0))).to be_nil
    end

    it "respects order-ahead eligibility, which is not a DRR feature" do
      later = flow(id: :later, items: 1, arrived_at: at(0), deadline: at(7200))
      s = state([ later ], policy: :fifo)

      expect(described_class.pick_next(s, at(0))).to be_nil
    end
  end

  describe "the ring pointer (§6.5)" do
    it "wraps rather than running off the end" do
      a = flow(id: :a, items: 1, arrived_at: at(0))
      b = flow(id: :b, items: 1, arrived_at: at(0))
      s = DeficitScheduler::State.new(flows: [ a, b ], config: DeficitScheduler::Config.new, pointer: 5)

      expect(described_class.pick_next(s, at(0))).not_to be_nil
    end

    it "draws the deficit down by exactly the drink's prep time" do
      f = flow(id: :f, items: 1, cost: 60, deficit: 200, arrived_at: at(0))
      # Quantum pinned rather than taken from the default: this example is about
      # the arithmetic, and it should not move when §10.5 retunes the default.
      s = state([ f ], quantum: 120, aging_enabled: false, staleness_enabled: false)

      described_class.pick_next(s, at(0))

      # 200 carried + 120 granted on arrival - 60 spent.
      expect(f.deficit).to eq(260)
    end

    # Exactly-equal is the case a `>` instead of `>=` would silently change, and
    # the one no test hits by accident.
    it "dispatches when the deficit exactly equals the prep time" do
      # One granted quantum lands exactly on the drink's cost.
      f = flow(id: :f, items: 1, cost: 120, deficit: 0, arrived_at: at(0))
      s = state([ f ], quantum: 120, aging_enabled: false, staleness_enabled: false)

      picked = described_class.pick_next(s, at(0))

      expect(picked[:item].cost).to eq(120)
      expect(f.deficit).to eq(0)
    end

    it "keeps the turn when a granted quantum is enough to afford the head" do
      f = flow(id: :f, items: 1, cost: 60, arrived_at: at(0))
      other = flow(id: :other, items: 1, arrived_at: at(0))
      s = state([ f, other ], aging_enabled: false, staleness_enabled: false)

      # One quantum covers a 60s drink, so :f dispatches on its own turn.
      expect(dispatch_all(s, now: at(0)).first).to eq(:f)
    end

    # Kills the `@granted_to == flow.id` → `@granted_to` mutant: truthiness alone
    # would treat *any* flow as already granted once one had been, so every
    # other flow would be visited without ever drawing a quantum.
    it "grants a quantum to each flow, not just the first one visited" do
      a = flow(id: :a, items: 1, cost: 100, arrived_at: at(0))
      b = flow(id: :b, items: 1, cost: 100, arrived_at: at(0))
      s = state([ a, b ], quantum: 100, aging_enabled: false, staleness_enabled: false)

      expect(dispatch_all(s, now: at(0)).sort).to eq([ :a, :b ])
    end

    it "hands the turn on when one quantum is not enough" do
      expensive = flow(id: :expensive, items: 1, cost: 500, arrived_at: at(0))
      cheap = flow(id: :cheap, items: 1, cost: 60, arrived_at: at(0))
      s = state([ expensive, cheap ], aging_enabled: false, staleness_enabled: false)

      expect(dispatch_all(s, now: at(0)).first).to eq(:cheap)
    end
  end

  describe "purity (§6.2, §10.1)" do
    # The constraint that makes the simulator meaningful. If this file ever
    # reaches for Time.now, simulated runs stop describing production.
    # Widened when this became a gem (ADR-0033): it used to read the one
    # scheduler.rb, but the package boundary covers every file, so every file is
    # checked. The gemspec declaring zero runtime dependencies is the harder
    # half of this guarantee — this catches the case where someone reaches for
    # a constant Ruby happens to provide anyway.
    it "reads the clock only through the injected argument" do
      paths = Dir[File.expand_path("../lib/**/*.rb", __dir__)]

      # Without this the example passes green if the glob ever matches nothing —
      # a renamed directory, a moved spec file — which is structurally the same
      # "matched nothing, therefore enforced nothing" failure ADR-0033 deleted
      # from the application's coverage hook. Six files today: the entry point
      # plus five.
      expect(paths.size).to be >= 6, "the purity glob matched #{paths.size} files; it should match every lib file"

      paths.each do |path|
        # Comments stripped: these files *discuss* ActiveRecord and the clock at
        # length, and matching prose would fire the guard on its own rationale.
        code = File.read(path).lines.grep_v(/^\s*#/).join

        expect(code).not_to match(/Time\.(now|current)/), "#{path} reads the clock directly"
        expect(code).not_to match(/\bActiveRecord\b/), "#{path} reaches for ActiveRecord"
        expect(code).not_to match(/\bRails\b/), "#{path} reaches for Rails"
      end
    end

    it "returns the same answer for the same inputs" do
      build = -> { state([ flow(id: :a, items: 2, arrived_at: at(0)), flow(id: :b, items: 2, arrived_at: at(5)) ]) }

      expect(dispatch_all(build.call, now: at(60))).to eq(dispatch_all(build.call, now: at(60)))
    end
  end

  # §6.3's comparison arms. Each removes one thing DRR does, so the ablation
  # chart can attribute a difference to it rather than assert one.
  describe "the comparison arms (§6.3)" do
    describe "plain round robin" do
      # The claim RR exists to make. DRR is RR plus the deficit, so when every
      # drink costs exactly one quantum the deficit has nothing left to correct
      # and the two produce the identical sequence — §1's "a menu where
      # everything takes the same time would hide the problem", as a test.
      it "is indistinguishable from DRR when a drink costs exactly one quantum" do
        flows = -> { [ flow(id: :a, items: 4, cost: 60), flow(id: :b, items: 4, cost: 60) ] }

        expect(dispatch_all(state(flows.call, policy: :rr)))
          .to eq(dispatch_all(state(flows.call, policy: :drr, quantum: 60,
                                    aging_enabled: false, staleness_enabled: false)))
      end

      # With uniform costs the two still divide the shop identically even when
      # the quantum buys several drinks a visit — only the granularity differs.
      it "divides the shop the same way as DRR whatever the quantum buys" do
        rr = dispatch_all(state([ flow(id: :a, items: 6, cost: 60), flow(id: :b, items: 6, cost: 60) ], policy: :rr))
        drr = dispatch_all(state([ flow(id: :a, items: 6, cost: 60), flow(id: :b, items: 6, cost: 60) ],
                                 policy: :drr, quantum: 120, aging_enabled: false, staleness_enabled: false))

        expect(rr.tally).to eq(drr.tally)
        expect(rr).not_to eq(drr), "a 120s quantum buys two 60s drinks a visit, so DRR is coarser"
      end

      # The bug a filtered ring hides: index into `dispatchable` and a draining
      # flow shifts everyone after it down one, so the pointer steps over
      # whichever flow moved into the vacated slot.
      it "does not skip a flow when an earlier one drains" do
        s = state([ flow(id: :short, items: 1), flow(id: :a, items: 2), flow(id: :b, items: 2) ], policy: :rr)

        expect(dispatch_all(s)).to eq(%i[short a b a b])
      end

      # And the claim it exists to *break*. Equal turns are not equal time: two
      # orders alternate one-for-one, so the expensive one takes 135/40 = 3.4x
      # the barista time while RR calls that fair.
      it "gives equal turns and therefore unequal time when the menu is spread" do
        cheap = flow(id: :cheap, items: 6, cost: 40)
        dear = flow(id: :dear, items: 6, cost: 135)

        sequence = dispatch_all(state([ cheap, dear ], policy: :rr))

        expect(sequence.each_slice(2).map(&:sort).uniq).to eq([ %i[cheap dear] ]),
          "RR should alternate strictly, got #{sequence.inspect}"
      end

      it "takes exactly one drink per order per turn" do
        sequence = dispatch_all(state([ flow(id: :a, items: 3), flow(id: :b, items: 3) ], policy: :rr))

        expect(sequence).to eq(%i[a b a b a b])
      end

      # No `priority_ring`, so none of DRR's boosts apply. If any of them leaked
      # in, the arm would no longer isolate the deficit.
      it "ignores aging, cohesion and the remake floor" do
        old = flow(id: :old, items: 2, arrived_at: at(-3600))
        half = flow(id: :half, items: 2, total_items: 4, first_output_at: at(-600))
        remade = flow(id: :remade, items: 2, expedited: true)
        s = state([ old, half, remade ], policy: :rr, aging_rate: 5.0, staleness_boost: 10.0, expedited_multiplier: 50.0)

        expect(dispatch_all(s, now: at(0))).to eq(%i[old half remade old half remade])
      end

      it "returns nil when nothing is dispatchable" do
        expect(described_class.pick_next(state([], policy: :rr), at(0))).to be_nil
      end
    end

    describe "shortest job first" do
      it "always takes the cheapest queued drink" do
        s = state([ flow(id: :dear, items: 2, cost: 135),
                    flow(id: :cheap, items: 2, cost: 40),
                    flow(id: :mid, items: 2, cost: 70) ], policy: :sjf)

        expect(dispatch_all(s)).to eq(%i[cheap cheap mid mid dear dear])
      end

      # The failure §1 exists to prevent, demonstrated rather than asserted.
      # This is why SJF is a benchmark and never a policy (§6.3).
      it "starves a large order under a stream of cheaper drinks" do
        catering = flow(id: :catering, items: 15, cost: 135, arrived_at: at(0))
        smalls = Array.new(30) { |i| flow(id: :"small_#{i}", items: 1, cost: 40, arrived_at: at(i * 5)) }

        sequence = dispatch_all(state([ catering, *smalls ], policy: :sjf), now: at(200))

        expect(sequence.first(30)).to all(start_with("small")), "the catering order should not get a look in"
        expect(sequence.index(:catering)).to eq(30)
      end

      it "breaks ties on arrival then id, so a run is reproducible" do
        a = flow(id: :a, items: 1, cost: 60, arrived_at: at(10))
        b = flow(id: :b, items: 1, cost: 60, arrived_at: at(0))

        expect(dispatch_all(state([ a, b ], policy: :sjf))).to eq(%i[b a])
      end

      it "returns nil when nothing is dispatchable" do
        expect(described_class.pick_next(state([], policy: :sjf), at(0))).to be_nil
      end
    end

    # A mis-typed policy in a sweep would otherwise run as DRR and look like a
    # null result rather than a mistake.
    it "refuses a policy it has no branch for" do
      expect { described_class.pick_next(state([ flow(id: :a) ], policy: :lifo), at(0)) }
        .to raise_error(ArgumentError, /unknown policy :lifo/)
    end
  end
end
