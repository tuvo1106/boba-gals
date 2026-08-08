require "scheduler_helper"

# The §11 checklist. Every case below is required before DRR ships — CLAUDE.md
# says not to merge the scheduler with any of them missing.
#
# These are the specs the design's central claim rests on: *a large order must
# not block small orders*. A green suite here is the difference between that
# being an assertion and being a property.
RSpec.describe Scheduler do
  describe "the fairness claim (§2, §11)" do
    # The headline case. Under FIFO the single drink waits behind fifteen
    # others — roughly fifteen minutes. Under DRR it waits about one drink.
    it "dispatches a single drink arriving behind a 15-drink order within one quantum" do
      catering = flow(id: :catering, drinks: 15, arrived_at: at(0))
      single = flow(id: :single, drinks: 1, arrived_at: at(10))
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
      large = flow(id: :large, drinks: 20, arrived_at: at(0))
      smalls = Array.new(40) { |i| flow(id: :"small_#{i}", drinks: 1, arrived_at: at(i * 5)) }
      s = state([ large, *smalls ])

      sequence = dispatch_all(s, now: at(200))

      expect(sequence.count(:large)).to eq(20), "the large order starved"
      expect(sequence.size).to eq(60)
    end

    it "interleaves rather than draining one order at a time" do
      a = flow(id: :a, drinks: 6, arrived_at: at(0))
      b = flow(id: :b, drinks: 6, arrived_at: at(0))
      s = state([ a, b ])

      sequence = dispatch_all(s, now: at(0))

      # Six of each; if it drained one order first the first six would be all :a.
      expect(sequence.first(6).uniq.size).to eq(2)
    end
  end

  describe "remakes (§6.4)" do
    it "puts a remake ahead of same-age normal work" do
      normal = flow(id: :normal, drinks: 1, arrived_at: at(0))
      remade = flow(id: :remade, drinks: 1, arrived_at: at(0), remake: true)
      s = state([ normal, remade ])

      expect(dispatch_all(s, now: at(0)).first).to eq(:remade)
    end

    # The reason §6.4 chose a floor over a fixed bump: two remakes must still
    # compete with each other by age.
    it "puts an older remake ahead of a newer one" do
      newer = flow(id: :newer, drinks: 1, arrived_at: at(600), remake: true)
      older = flow(id: :older, drinks: 1, arrived_at: at(0), remake: true)
      s = state([ newer, older ])

      expect(dispatch_all(s, now: at(600)).first).to eq(:older)
    end

    # Kills the `any?` → `all?` mutant. A remade drink joins an order that still
    # has ordinary drinks in it, so a flow is almost never all-remake — reading
    # `all?` would quietly withdraw the floor from every real remake.
    it "gives the floor to an order carrying one remake among ordinary drinks" do
      mixed = Scheduler::Flow.new(
        id: :mixed, arrived_at: at(0),
        queue: [ item(enqueued_at: at(0)), item(enqueued_at: at(0), remake: true) ]
      )
      normal = flow(id: :normal, drinks: 2, arrived_at: at(0))

      expect(dispatch_all(state([ normal, mixed ]), now: at(0)).first).to eq(:mixed)
    end

    # A fixed additive bump gets swamped: after 20 minutes of aging a normal
    # order's multiplier would exceed a fresh remake's. The floor must hold.
    it "keeps a fresh remake ahead of a long-aged normal order" do
      aged = flow(id: :aged, drinks: 1, arrived_at: at(0))
      fresh_remake = flow(id: :fresh_remake, drinks: 1, arrived_at: at(1800), remake: true)
      s = state([ aged, fresh_remake ])

      expect(dispatch_all(s, now: at(1800)).first).to eq(:fresh_remake)
    end
  end

  # Off by default since ADR-0014 measured it making spread worse, so these
  # enable it explicitly. They are kept, and still assert the mechanism does
  # what §6.2 says: the knob has to keep working for the finding to stay
  # reproducible, and for a re-triggered version to have somewhere to land.
  describe "cohesion (§6.4, §9.6), enabled explicitly" do
    # §6.4's motivating case is the small multi-drink order whose first drink
    # sits and melts. A `> 1` that drifted to `> 2` would silently exclude it.
    it "boosts a two-drink order with one drink already made" do
      pair = flow(id: :pair, drinks: 1, total_items: 2, made_count: 1, arrived_at: at(0))
      config = Scheduler::Config.new(aging_enabled: false, cohesion_enabled: true)

      expect(described_class.quantum_for(pair, at(0), config)).to eq(240.0)
    end

    # Every other cohesion example sits exactly on the threshold, which lets an
    # `>=` degrade to an equality test unnoticed — an order at 75% made would
    # silently lose its boost.
    it "keeps boosting past the threshold, not only at it" do
      mostly = flow(id: :mostly, drinks: 1, total_items: 4, made_count: 3, arrived_at: at(0))
      config = Scheduler::Config.new(aging_enabled: false, cohesion_enabled: true)

      expect(described_class.quantum_for(mostly, at(0), config)).to eq(240.0)
    end

    # Kills the `made_count / total_items` → `made_count` mutant: a raw count of
    # 1 clears a 0.5 threshold, a ratio of 1/4 does not.
    it "measures the fraction made, not the number made" do
      quarter = flow(id: :quarter, drinks: 3, total_items: 4, made_count: 1, arrived_at: at(0))
      config = Scheduler::Config.new(aging_enabled: false, cohesion_enabled: true)

      expect(described_class.quantum_for(quarter, at(0), config)).to eq(120.0)
    end

    it "puts an order past half made ahead of an equal-age order at zero" do
      half_made = flow(id: :half_made, drinks: 2, total_items: 4, made_count: 2, arrived_at: at(0))
      untouched = flow(id: :untouched, drinks: 4, total_items: 4, made_count: 0, arrived_at: at(0))
      s = state([ untouched, half_made ], cohesion_enabled: true)

      expect(dispatch_all(s, now: at(0)).first).to eq(:half_made)
    end

    it "does not boost a single-drink order, which cannot have a melting first drink" do
      single = flow(id: :single, drinks: 1, total_items: 1, made_count: 1, arrived_at: at(0))

      expect(described_class.quantum_for(single, at(0), Scheduler::Config.new(aging_enabled: false, cohesion_enabled: true)))
        .to eq(120.0)
    end

    it "can be switched off" do
      half_made = flow(id: :half_made, drinks: 2, total_items: 4, made_count: 2, arrived_at: at(0))
      config = Scheduler::Config.new(cohesion_enabled: false, aging_enabled: false)

      expect(described_class.quantum_for(half_made, at(0), config)).to eq(120.0)
    end
  end

  describe "aging (§6.2)" do
    it "grows the quantum with waiting time so nothing starves" do
      waited = flow(id: :waited, arrived_at: at(0))
      config = Scheduler::Config.new(cohesion_enabled: false)

      # 10 minutes × 0.15/min = +1.5 → 2.5 × 120
      expect(described_class.quantum_for(waited, at(600), config)).to eq(300.0)
    end

    it "can be switched off" do
      waited = flow(id: :waited, arrived_at: at(0))
      config = Scheduler::Config.new(aging_enabled: false, cohesion_enabled: false)

      expect(described_class.quantum_for(waited, at(600), config)).to eq(120.0)
    end
  end

  describe "order-ahead eligibility (§6.2)" do
    it "will not start an order promised two hours out" do
      later = flow(id: :later, drinks: 1, arrived_at: at(0), promised_at: at(7200))
      s = state([ later ])

      expect(described_class.pick_next(s, at(0))).to be_nil
    end

    # Backward-scheduled start = promised_at − remaining work − promise_buffer.
    # One 60s drink with the default 120s buffer means 180s before the promise.
    it "becomes eligible at its backward-scheduled start, not before" do
      later = flow(id: :later, drinks: 1, prep_seconds: 60, arrived_at: at(0), promised_at: at(1000))
      config = Scheduler::Config.new

      expect(described_class.eligible?(later, at(819), config)).to be(false)
      expect(described_class.eligible?(later, at(820), config)).to be(true)
    end

    # Kills the `>=` → `==` mutant: testing only the boundary instant leaves a
    # scheduler that is eligible for exactly one second and never again.
    it "stays eligible once its start has passed" do
      later = flow(id: :later, drinks: 1, prep_seconds: 60, arrived_at: at(0), promised_at: at(1000))

      expect(described_class.eligible?(later, at(900), Scheduler::Config.new)).to be(true)
    end

    it "treats an ASAP order as always eligible" do
      asap = flow(id: :asap, drinks: 1, arrived_at: at(0))

      expect(described_class.eligible?(asap, at(0), Scheduler::Config.new)).to be(true)
    end

    it "skips a not-yet-due order without blocking the ones behind it" do
      later = flow(id: :later, drinks: 1, arrived_at: at(0), promised_at: at(7200))
      asap = flow(id: :asap, drinks: 1, arrived_at: at(0))
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
      drained = flow(id: :drained, drinks: 0)

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
      stuck = flow(id: :stuck, drinks: 1, prep_seconds: 60, arrived_at: at(0))
      s = state([ stuck ], quantum: 0, aging_enabled: false, cohesion_enabled: false)

      expect { described_class.pick_next(s, at(0)) }
        .to raise_error(Scheduler::LivelockError, /livelock/)
    end
  end

  describe "the FIFO control arm (§6.3)" do
    it "dispatches in strict enqueued_at, id order" do
      first = flow(id: :first, drinks: 1, arrived_at: at(0))
      second = flow(id: :second, drinks: 1, arrived_at: at(10))
      third = flow(id: :third, drinks: 1, arrived_at: at(20))
      s = state([ third, first, second ], policy: :fifo)

      expect(dispatch_all(s, now: at(100))).to eq([ :first, :second, :third ])
    end

    # The point of keeping FIFO: it is the control arm, so it must *not* do any
    # of the things DRR does. A remake gets no floor here.
    it "ignores remakes, aging, and cohesion entirely" do
      normal = flow(id: :normal, drinks: 1, arrived_at: at(0))
      remade = flow(id: :remade, drinks: 1, arrived_at: at(10), remake: true)
      s = state([ normal, remade ], policy: :fifo)

      expect(dispatch_all(s, now: at(100))).to eq([ :normal, :remade ])
    end

    # Kills the `[enqueued_at, id]` → `[nil, id]` mutant: with ids ordered
    # against arrival, only a real enqueued_at comparison gets this right.
    it "orders by enqueued_at even when item ids disagree" do
      early = Scheduler::Flow.new(id: :early, arrived_at: at(0),
                                  queue: [ item(id: 99, enqueued_at: at(0)) ])
      late = Scheduler::Flow.new(id: :late, arrived_at: at(0),
                                 queue: [ item(id: 1, enqueued_at: at(500)) ])

      expect(dispatch_all(state([ late, early ], policy: :fifo), now: at(500)))
        .to eq([ :early, :late ])
    end

    it "breaks ties on item id so the sequence is deterministic" do
      a = Scheduler::Flow.new(id: :a, arrived_at: at(0),
                              queue: [ item(id: 2, enqueued_at: at(0)) ])
      b = Scheduler::Flow.new(id: :b, arrived_at: at(0),
                              queue: [ item(id: 1, enqueued_at: at(0)) ])

      expect(dispatch_all(state([ a, b ], policy: :fifo), now: at(0))).to eq([ :b, :a ])
    end

    it "returns nil when nothing is dispatchable" do
      expect(described_class.pick_next(state([], policy: :fifo), at(0))).to be_nil
    end

    it "respects order-ahead eligibility, which is not a DRR feature" do
      later = flow(id: :later, drinks: 1, arrived_at: at(0), promised_at: at(7200))
      s = state([ later ], policy: :fifo)

      expect(described_class.pick_next(s, at(0))).to be_nil
    end
  end

  describe "the ring pointer (§6.5)" do
    it "wraps rather than running off the end" do
      a = flow(id: :a, drinks: 1, arrived_at: at(0))
      b = flow(id: :b, drinks: 1, arrived_at: at(0))
      s = Scheduler::State.new(flows: [ a, b ], config: Scheduler::Config.new, pointer: 5)

      expect(described_class.pick_next(s, at(0))).not_to be_nil
    end

    it "draws the deficit down by exactly the drink's prep time" do
      f = flow(id: :f, drinks: 1, prep_seconds: 60, deficit: 200, arrived_at: at(0))
      s = state([ f ], aging_enabled: false, cohesion_enabled: false)

      described_class.pick_next(s, at(0))

      # 200 carried + 120 granted on arrival - 60 spent.
      expect(f.deficit).to eq(260)
    end

    # Exactly-equal is the case a `>` instead of `>=` would silently change, and
    # the one no test hits by accident.
    it "dispatches when the deficit exactly equals the prep time" do
      # One granted quantum lands exactly on the drink's cost.
      f = flow(id: :f, drinks: 1, prep_seconds: 120, deficit: 0, arrived_at: at(0))
      s = state([ f ], aging_enabled: false, cohesion_enabled: false)

      picked = described_class.pick_next(s, at(0))

      expect(picked[:item].prep_seconds).to eq(120)
      expect(f.deficit).to eq(0)
    end

    it "keeps the turn when a granted quantum is enough to afford the head" do
      f = flow(id: :f, drinks: 1, prep_seconds: 60, arrived_at: at(0))
      other = flow(id: :other, drinks: 1, arrived_at: at(0))
      s = state([ f, other ], aging_enabled: false, cohesion_enabled: false)

      # One 120s quantum covers a 60s drink, so :f dispatches on its own turn.
      expect(dispatch_all(s, now: at(0)).first).to eq(:f)
    end

    # Kills the `@granted_to == flow.id` → `@granted_to` mutant: truthiness alone
    # would treat *any* flow as already granted once one had been, so every
    # other flow would be visited without ever drawing a quantum.
    it "grants a quantum to each flow, not just the first one visited" do
      a = flow(id: :a, drinks: 1, prep_seconds: 100, arrived_at: at(0))
      b = flow(id: :b, drinks: 1, prep_seconds: 100, arrived_at: at(0))
      s = state([ a, b ], quantum: 100, aging_enabled: false, cohesion_enabled: false)

      expect(dispatch_all(s, now: at(0)).sort).to eq([ :a, :b ])
    end

    it "hands the turn on when one quantum is not enough" do
      expensive = flow(id: :expensive, drinks: 1, prep_seconds: 500, arrived_at: at(0))
      cheap = flow(id: :cheap, drinks: 1, prep_seconds: 60, arrived_at: at(0))
      s = state([ expensive, cheap ], aging_enabled: false, cohesion_enabled: false)

      expect(dispatch_all(s, now: at(0)).first).to eq(:cheap)
    end
  end

  describe "purity (§6.2, §10.1)" do
    # The constraint that makes the simulator meaningful. If this file ever
    # reaches for Time.now, simulated runs stop describing production.
    it "reads the clock only through the injected argument" do
      # Comments stripped: this file *discusses* ActiveRecord and the clock at
      # length, and matching prose would make the guard fire on its own rationale.
      source = File.read(File.expand_path("../../app/scheduler/scheduler.rb", __dir__))
      code = source.lines.grep_v(/^\s*#/).join

      expect(code).not_to match(/Time\.(now|current)/)
      expect(code).not_to match(/\bActiveRecord\b/)
    end

    it "returns the same answer for the same inputs" do
      build = -> { state([ flow(id: :a, drinks: 2, arrived_at: at(0)), flow(id: :b, drinks: 2, arrived_at: at(5)) ]) }

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
        flows = -> { [ flow(id: :a, drinks: 4, prep_seconds: 60), flow(id: :b, drinks: 4, prep_seconds: 60) ] }

        expect(dispatch_all(state(flows.call, policy: :rr)))
          .to eq(dispatch_all(state(flows.call, policy: :drr, quantum: 60,
                                    aging_enabled: false, cohesion_enabled: false)))
      end

      # With uniform costs the two still divide the shop identically even when
      # the quantum buys several drinks a visit — only the granularity differs.
      it "divides the shop the same way as DRR whatever the quantum buys" do
        rr = dispatch_all(state([ flow(id: :a, drinks: 6, prep_seconds: 60), flow(id: :b, drinks: 6, prep_seconds: 60) ], policy: :rr))
        drr = dispatch_all(state([ flow(id: :a, drinks: 6, prep_seconds: 60), flow(id: :b, drinks: 6, prep_seconds: 60) ],
                                 policy: :drr, aging_enabled: false, cohesion_enabled: false))

        expect(rr.tally).to eq(drr.tally)
        expect(rr).not_to eq(drr), "a 120s quantum buys two 60s drinks a visit, so DRR is coarser"
      end

      # The bug a filtered ring hides: index into `dispatchable` and a draining
      # flow shifts everyone after it down one, so the pointer steps over
      # whichever flow moved into the vacated slot.
      it "does not skip a flow when an earlier one drains" do
        s = state([ flow(id: :short, drinks: 1), flow(id: :a, drinks: 2), flow(id: :b, drinks: 2) ], policy: :rr)

        expect(dispatch_all(s)).to eq(%i[short a b a b])
      end

      # And the claim it exists to *break*. Equal turns are not equal time: two
      # orders alternate one-for-one, so the expensive one takes 135/40 = 3.4x
      # the barista time while RR calls that fair.
      it "gives equal turns and therefore unequal time when the menu is spread" do
        cheap = flow(id: :cheap, drinks: 6, prep_seconds: 40)
        dear = flow(id: :dear, drinks: 6, prep_seconds: 135)

        sequence = dispatch_all(state([ cheap, dear ], policy: :rr))

        expect(sequence.each_slice(2).map(&:sort).uniq).to eq([ %i[cheap dear] ]),
          "RR should alternate strictly, got #{sequence.inspect}"
      end

      it "takes exactly one drink per order per turn" do
        sequence = dispatch_all(state([ flow(id: :a, drinks: 3), flow(id: :b, drinks: 3) ], policy: :rr))

        expect(sequence).to eq(%i[a b a b a b])
      end

      # No `priority_ring`, so none of DRR's boosts apply. If any of them leaked
      # in, the arm would no longer isolate the deficit.
      it "ignores aging, cohesion and the remake floor" do
        old = flow(id: :old, drinks: 2, arrived_at: at(-3600))
        half = flow(id: :half, drinks: 2, made_count: 2, total_items: 4)
        remade = flow(id: :remade, drinks: 2, remake: true)
        s = state([ old, half, remade ], policy: :rr, aging_rate: 5.0, cohesion_boost: 10.0, remake_multiplier: 50.0)

        expect(dispatch_all(s, now: at(0))).to eq(%i[old half remade old half remade])
      end

      it "returns nil when nothing is dispatchable" do
        expect(described_class.pick_next(state([], policy: :rr), at(0))).to be_nil
      end
    end

    describe "shortest job first" do
      it "always takes the cheapest queued drink" do
        s = state([ flow(id: :dear, drinks: 2, prep_seconds: 135),
                    flow(id: :cheap, drinks: 2, prep_seconds: 40),
                    flow(id: :mid, drinks: 2, prep_seconds: 70) ], policy: :sjf)

        expect(dispatch_all(s)).to eq(%i[cheap cheap mid mid dear dear])
      end

      # The failure §1 exists to prevent, demonstrated rather than asserted.
      # This is why SJF is a benchmark and never a policy (§6.3).
      it "starves a large order under a stream of cheaper drinks" do
        catering = flow(id: :catering, drinks: 15, prep_seconds: 135, arrived_at: at(0))
        smalls = Array.new(30) { |i| flow(id: :"small_#{i}", drinks: 1, prep_seconds: 40, arrived_at: at(i * 5)) }

        sequence = dispatch_all(state([ catering, *smalls ], policy: :sjf), now: at(200))

        expect(sequence.first(30)).to all(start_with("small")), "the catering order should not get a look in"
        expect(sequence.index(:catering)).to eq(30)
      end

      it "breaks ties on arrival then id, so a run is reproducible" do
        a = flow(id: :a, drinks: 1, prep_seconds: 60, arrived_at: at(10))
        b = flow(id: :b, drinks: 1, prep_seconds: 60, arrived_at: at(0))

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
