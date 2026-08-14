# Deficit Round Robin over orders (DESIGN.md §6.1, §6.2).
#
# The design's central claim lives here: *a large order must not block small
# orders*. Because the flow is the order and the packet is the drink (§2), a
# 15-drink catering order competes for one turn of the ring rather than fifteen,
# so the customer behind it waits roughly one drink's time.
#
# **Pure**: no ActiveRecord, no clock access, no I/O. `now` is injected, and the
# simulator (§10.1) calls this exact method with a SimClock — that is the one
# rule that makes the simulator's results mean anything about production.
#
# "Pure" here means deterministic given `(state, now)`, not free of side effects
# on its argument: the algorithm advances the ring pointer and draws down
# deficits, exactly as §6.2 specifies, and §6.5 persists both to Redis.
module Scheduler
  # The ring can legitimately spin a few times per dispatch — once per flow that
  # needs a quantum before it can afford its head drink. It must not spin
  # forever. A trip here is a bug in this file, not a busy shop, so it raises
  # rather than returning nil and letting the kitchen quietly stall.
  LIVELOCK_GUARD = 10_000

  class LivelockError < StandardError; end

  # Picks the next drink to dispatch.
  #
  # @param state [Scheduler::State] flows, ring pointer, and config
  # @param now [Time] injected clock reading
  # @return [Hash{Symbol => Object}, nil] `{ flow:, item: }`, or nil when nothing
  #   is dispatchable
  def self.pick_next(state, now)
    return pick_arm(state, now) unless state.config.drr?

    return nil if dispatchable(state, now).empty?

    guard = 0

    loop do
      guard += 1
      raise LivelockError, "scheduler livelock after #{LIVELOCK_GUARD} rounds" if guard > LIVELOCK_GUARD

      ring = priority_ring(state, now)
      state.pointer = 0 if state.pointer >= ring.size
      flow = ring[state.pointer]

      unless dispatchable?(flow, now, state.config)
        state.advance!
        next
      end

      # One quantum per flow per visit. §6.2's pseudocode grants inside the loop
      # without tracking this, which lets a flow top itself up indefinitely and
      # never yield the ring — see Scheduler::State#granted?.
      unless state.granted?(flow)
        flow.deficit += quantum_for(flow, now, state.config)
        state.grant!(flow)
      end

      head = flow.head

      if flow.deficit >= head.prep_seconds
        flow.deficit -= head.prep_seconds
        return { flow: flow, item: flow.queue.shift }
      end

      # This visit's quantum is spent. The unspent remainder carries — that is
      # the "deficit" the algorithm is named for, and it is what stops a flow
      # with expensive drinks from being starved by the rounding.
      state.advance!
    end
  end

  # A §6.3 comparison arm. None of these carry a deficit, age, or cohere — that
  # is the point: each removes one thing DRR does so the chart can attribute the
  # difference to it.
  #
  # @param state [Scheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_arm(state, now)
    case state.config.validate!.policy
    when :fifo then pick_fifo(state, now)
    when :rr   then pick_rr(state, now)
    else            pick_sjf(state, now)
    end
  end

  # The §6.3 control arm, kept permanently: strict arrival order, no deficits,
  # no aging. This is what the ablation study (§10.5) measures DRR against, and
  # the fallback if DRR misbehaves in production.
  #
  # @param state [Scheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_fifo(state, now)
    flow = dispatchable(state, now).min_by { |f| [ f.head.enqueued_at, f.head.id ] }
    return nil if flow.nil?

    { flow: flow, item: flow.queue.shift }
  end

  # Plain round robin: one drink per order per turn, `prep_seconds` ignored
  # (§6.3).
  #
  # This is DRR with the deficit removed, and nothing else changed — no
  # `priority_ring`, so aging, cohesion and the remake floor are all absent too.
  # Reintroducing any of them here would smuggle back part of what the arm
  # exists to isolate.
  #
  # Equal *turns* are not equal *time*: a Brown Sugar Pearl with three toppings
  # is 135s against a Thai Tea's 40s (§1), so an order of the former takes 3.4x
  # the barista time per round. The deficit is what converts turns into time.
  #
  # @param state [Scheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_rr(state, now)
    ring = state.flows

    # Walks every flow and skips the undispatchable, rather than indexing into
    # `dispatchable`'s filtered array. Filtering first looks simpler and is
    # wrong: when a flow drains, every later flow shifts down one index and the
    # pointer steps over whichever flow took the vacated slot. That skipped flow
    # loses its turn, which in a round robin is the one thing that must not
    # happen.
    ring.size.times do
      state.pointer = 0 if state.pointer >= ring.size
      flow = ring[state.pointer]
      state.advance!

      return { flow: flow, item: flow.queue.shift } if dispatchable?(flow, now, state.config)
    end

    nil
  end

  # Shortest job first (§6.3): always the cheapest queued drink.
  #
  # Minimises mean wait — provably so on a single station — and starves large
  # orders while doing it, which is exactly the failure §1 exists to prevent.
  # It is here as the bound DRR is paying against, never as a policy: §6.6's
  # allowlist does not accept it.
  #
  # @param state [Scheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_sjf(state, now)
    flow = dispatchable(state, now)
             .min_by { |f| [ f.head.prep_seconds, f.head.enqueued_at, f.head.id ] }
    return nil if flow.nil?

    { flow: flow, item: flow.queue.shift }
  end

  # The quantum this flow earns on its turn (§6.2).
  #
  # Multipliers are additive on purpose. Stacking them multiplicatively would
  # let an aged remake on a half-made order dwarf everything else by an order of
  # magnitude; adding keeps the boosts comparable and bounded.
  #
  # @param flow [Scheduler::Flow]
  # @param now [Time]
  # @param config [Scheduler::Config]
  # @return [Float] seconds of quantum
  def self.quantum_for(flow, now, config)
    multiplier = 1.0

    # Aging: nothing starves, even under a continuous stream of small orders.
    if config.aging_enabled
      # Clamped at zero. `now` earlier than `flow.arrived_at` shouldn't happen
      # in production — §6.5 builds the flow set from already-queued items, so
      # arrival precedes dispatch by construction — but clock skew between the
      # two `web` pods (§14.2, §14.4) could produce a few hundred milliseconds
      # of it. Left unclamped, a negative multiplier shrinks the deficit on
      # every visit instead of growing it, which trips LIVELOCK_GUARD (issue
      # #49). Clamping makes a clock-skewed dispatch behave exactly like a
      # just-arrived order, which is correct either way.
      waited_minutes = [ (now - flow.arrived_at) / 60.0, 0 ].max
      multiplier += config.aging_rate * waited_minutes
    end

    # Cohesion: the earliest finished drink accrues quantum the longer it sits,
    # rather than the order accruing it once past half made — shaped exactly
    # like aging above (§6.4, §9.6, #31, ADR-0032).
    #
    # ADR-0014's original trigger (`fraction_made >= 0.5`) measured the wrong
    # quantity: an order can be 90% made with nothing sitting, or 30% made with
    # a drink going stale. It made `cohesion_spread` monotonically worse at
    # every load and order size. `total_items > 1` guards a case aging doesn't
    # need to: a single-drink order reaches `ready` the same instant it reaches
    # `first_ready_at` and leaves the flow set before the next rebuild, so real
    # callers never produce `total_items == 1` with `first_ready_at` set — but
    # nothing in this file guarantees that, so the guard stays reachable and
    # tested rather than assumed.
    if config.cohesion_enabled && flow.total_items > 1 && flow.first_ready_at
      sitting_minutes = [ (now - flow.first_ready_at) / 60.0, 0 ].max
      multiplier += config.cohesion_boost * sitting_minutes
    end

    # Remake: extra throughput once a remake is being served. The *ordering*
    # guarantee §6.4 calls a "priority floor" lives in `priority_ring`, because
    # a number added here is a rate, not a rank (ADR-0009). This still matters —
    # it is what lets a remade order clear faster once its turn comes.
    multiplier += config.remake_multiplier if flow.pending_remake?

    config.quantum * multiplier
  end

  # Backward scheduling for order-ahead: don't make an 11am pickup at 9am (§6.2).
  #
  # @param flow [Scheduler::Flow]
  # @param now [Time]
  # @param config [Scheduler::Config]
  # @return [Boolean]
  def self.eligible?(flow, now, config)
    return true if flow.promised_at.nil?

    remaining = flow.queue.sum(&:prep_seconds)
    target_start = flow.promised_at - remaining - config.promise_buffer

    now >= target_start
  end

  # The order the ring is walked in (ADR-0009).
  #
  # §6.2 walks flows in arrival order. That makes the quantum multiplier a
  # *rate* control — a boosted flow gets more service per round — but never a
  # priority: whichever flow sits at index 0 is still asked first. §6.4 and §11
  # both claim remakes "outrank" same-age normal work, which arrival order
  # cannot deliver.
  #
  # Reordering visits costs nothing in fairness, because DRR's fairness lives in
  # the deficit accounting rather than the visit order. Every flow still draws
  # exactly one quantum per round and nothing starves.
  #
  # Remakes are a separate *tier*, not a bigger number. §6.4 asks for "a
  # priority floor, not a fixed bump" and then §6.2 implements `multiplier +=
  # 4.0` — which is a fixed bump, and is swamped by aging after ~27 minutes
  # (a normal order reaches 1 + 0.15 × 27 ≈ 5.0). A floor has to be a tier or it
  # is not a floor.
  #
  # @return [Array<Scheduler::Flow>]
  def self.priority_ring(state, now)
    state.flows.each_with_index.sort_by do |flow, index|
      [
        flow.pending_remake? ? 0 : 1,                    # the floor (§6.4)
        -quantum_for(flow, now, state.config),           # aging and cohesion
        index                                            # stable, so ties are deterministic
      ]
    end.map(&:first)
  end

  # @return [Array<Scheduler::Flow>] flows with work that is due
  def self.dispatchable(state, now)
    state.flows.select { |flow| dispatchable?(flow, now, state.config) }
  end

  # No nil guard: the ring is built from `state.flows`, and the pointer is
  # wrapped before indexing, so there is no reachable path where this is called
  # with nil. The 100% branch gate (ADR-0002) is what surfaced that the guard
  # §6.2 carries is unreachable here.
  #
  # @return [Boolean]
  def self.dispatchable?(flow, now, config)
    return false if flow.empty?

    eligible?(flow, now, config)
  end

  private_class_method :dispatchable, :dispatchable?, :priority_ring
end
