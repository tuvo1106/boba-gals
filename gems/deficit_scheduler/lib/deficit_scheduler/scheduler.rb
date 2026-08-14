# Deficit round robin over flows (Shreedhar & Varghese, 1995), with aging, a
# priority tier, deadline scheduling, and a staleness boost.
#
# The central claim lives here: *a large flow must not block small ones*.
# Because the flow is the unit of competition and the item is the unit of work,
# a flow holding fifteen items competes for one turn of the ring rather than
# fifteen, so whoever is behind it waits roughly one item's time.
#
# **Pure**: no clock access, no I/O, no persistence. `now` is injected, which is
# what lets a simulator call this exact method with a simulated clock — the one
# rule that makes simulated results mean anything about production.
#
# "Pure" here means deterministic given `(state, now)`, not free of side effects
# on its argument: the algorithm advances the ring pointer and draws down
# deficits, which is the algorithm, and a consumer may persist both.
module DeficitScheduler
  # The ring can legitimately spin a few times per dispatch — once per flow that
  # needs a quantum before it can afford its head item. It must not spin forever.
  # A trip here is a bug in this file, not a busy queue, so it raises rather than
  # returning nil and letting the caller quietly stall.
  LIVELOCK_GUARD = 10_000

  class LivelockError < StandardError; end

  # Picks the next item to dispatch.
  #
  # @param state [DeficitScheduler::State] flows, ring pointer, and config
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

      # One quantum per flow per visit. The textbook pseudocode grants inside the
      # loop without tracking this, which lets a flow top itself up indefinitely
      # and never yield the ring — see State#granted?.
      unless state.granted?(flow)
        flow.deficit += quantum_for(flow, now, state.config)
        state.grant!(flow)
      end

      head = flow.head

      if flow.deficit >= head.cost
        flow.deficit -= head.cost
        return { flow: flow, item: flow.queue.shift }
      end

      # This visit's quantum is spent. The unspent remainder carries — that is
      # the "deficit" the algorithm is named for, and it is what stops a flow
      # with expensive items from being starved by the rounding.
      state.advance!
    end
  end

  # A comparison arm. None of these carry a deficit, age, or boost — that is the
  # point: each removes one thing DRR does, so a benchmark can attribute the
  # difference to it.
  #
  # @param state [DeficitScheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_arm(state, now)
    case state.config.validate!.policy
    when :fifo then pick_fifo(state, now)
    when :rr   then pick_rr(state, now)
    else            pick_sjf(state, now)
    end
  end

  # The control arm, kept permanently: strict arrival order, no deficits, no
  # aging. This is what the fairness claim is measured against, and the fallback
  # if DRR ever misbehaves in production.
  #
  # @param state [DeficitScheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_fifo(state, now)
    flow = dispatchable(state, now).min_by { |f| [ f.head.enqueued_at, f.head.id ] }
    return nil if flow.nil?

    { flow: flow, item: flow.queue.shift }
  end

  # Plain round robin: one item per flow per turn, `cost` ignored.
  #
  # This is DRR with the deficit removed, and nothing else changed — no
  # `priority_ring`, so aging, staleness and the expedited tier are all absent
  # too. Reintroducing any of them here would smuggle back part of what the arm
  # exists to isolate.
  #
  # Equal *turns* are not equal *service*: if one flow's items cost 135 and
  # another's cost 40, the first takes 3.4x the capacity per round. The deficit
  # is what converts turns into service.
  #
  # @param state [DeficitScheduler::State]
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

  # Shortest job first: always the cheapest queued item.
  #
  # Minimises mean wait — provably so on a single server — and starves large
  # flows while doing it, which is exactly the failure this scheduler exists to
  # prevent. It is here as the bound DRR is paying against, never as a setting.
  #
  # @param state [DeficitScheduler::State]
  # @param now [Time]
  # @return [Hash{Symbol => Object}, nil]
  def self.pick_sjf(state, now)
    flow = dispatchable(state, now)
             .min_by { |f| [ f.head.cost, f.head.enqueued_at, f.head.id ] }
    return nil if flow.nil?

    { flow: flow, item: flow.queue.shift }
  end

  # The quantum this flow earns on its turn.
  #
  # Multipliers are additive on purpose. Stacking them multiplicatively would let
  # an aged, expedited, stale flow dwarf everything else by an order of
  # magnitude; adding keeps the boosts comparable and bounded.
  #
  # @param flow [DeficitScheduler::Flow]
  # @param now [Time]
  # @param config [DeficitScheduler::Config]
  # @return [Float] quantum, in the same unit as `Item#cost`
  def self.quantum_for(flow, now, config)
    multiplier = 1.0

    # Aging: nothing starves, even under a continuous stream of small flows.
    if config.aging_enabled
      # Clamped at zero. `now` earlier than `flow.arrived_at` should not happen
      # when the flow set is built from already-queued work, since arrival
      # precedes dispatch by construction — but clock skew between two processes
      # can produce a few hundred milliseconds of it. Left unclamped, a negative
      # multiplier shrinks the deficit on every visit instead of growing it,
      # which trips LIVELOCK_GUARD. Clamping makes a clock-skewed dispatch behave
      # exactly like a just-arrived flow, which is correct either way.
      waited_minutes = [ (now - flow.arrived_at) / 60.0, 0 ].max
      multiplier += config.aging_rate * waited_minutes
    end

    # Staleness: a flow whose earliest output is already sitting accrues quantum
    # the longer it sits, so it can be finished and delivered rather than left
    # half-done while its first item degrades. Shaped exactly like aging above.
    #
    # Keyed on elapsed sitting time, deliberately, rather than on how much of the
    # flow is complete. Those are different quantities — a flow can be 90% done
    # with nothing sitting, or 30% done with its first output going off — and
    # keying on completion measurably made the thing it was meant to fix worse.
    #
    # `total_items > 1` guards a case aging does not need to: a single-item flow
    # completes at the same instant it produces its first output and leaves the
    # flow set before the next rebuild, so real callers never produce
    # `total_items == 1` with `first_output_at` set. Nothing in this file
    # guarantees that, though, so the guard stays reachable and tested rather
    # than assumed.
    if config.staleness_enabled && flow.total_items > 1 && flow.first_output_at
      sitting_minutes = [ (now - flow.first_output_at) / 60.0, 0 ].max
      multiplier += config.staleness_boost * sitting_minutes
    end

    # Expedited: extra throughput once expedited work is being served. The
    # *ordering* guarantee lives in `priority_ring`, because a number added here
    # is a rate, not a rank. This still matters — it is what lets an expedited
    # flow clear faster once its turn comes.
    multiplier += config.expedited_multiplier if flow.pending_expedited?

    config.quantum * multiplier
  end

  # Backward scheduling for deadlines: don't start an 11am job at 9am.
  #
  # @param flow [DeficitScheduler::Flow]
  # @param now [Time]
  # @param config [DeficitScheduler::Config]
  # @return [Boolean]
  def self.eligible?(flow, now, config)
    return true if flow.deadline.nil?

    remaining = flow.queue.sum(&:cost)
    target_start = flow.deadline - remaining - config.deadline_buffer

    now >= target_start
  end

  # The order the ring is walked in.
  #
  # Walking flows in plain arrival order makes the quantum multiplier a *rate*
  # control — a boosted flow gets more service per round — but never a priority:
  # whichever flow sits at index 0 is still asked first. That cannot deliver
  # "expedited work outranks same-age normal work", which is a statement about
  # rank rather than rate.
  #
  # Reordering visits costs nothing in fairness, because DRR's fairness lives in
  # the deficit accounting rather than the visit order. Every flow still draws
  # exactly one quantum per round and nothing starves.
  #
  # Expedited work is a separate *tier*, not a bigger number. A fixed bump is
  # swamped by aging soon enough — with the default rate, an ordinary flow
  # overtakes a `+4.0` bump after about 27 minutes of waiting. A floor has to be
  # a tier or it is not a floor.
  #
  # @return [Array<DeficitScheduler::Flow>]
  def self.priority_ring(state, now)
    state.flows.each_with_index.sort_by do |flow, index|
      [
        flow.pending_expedited? ? 0 : 1,                 # the tier
        -quantum_for(flow, now, state.config),           # aging and staleness
        index                                            # stable, so ties are deterministic
      ]
    end.map(&:first)
  end

  # @return [Array<DeficitScheduler::Flow>] flows with work that is due
  def self.dispatchable(state, now)
    state.flows.select { |flow| dispatchable?(flow, now, state.config) }
  end

  # No nil guard: the ring is built from `state.flows`, and the pointer is
  # wrapped before indexing, so there is no reachable path where this is called
  # with nil. The 100% branch-coverage gate is what surfaced that the guard the
  # textbook version carries is unreachable here.
  #
  # @return [Boolean]
  def self.dispatchable?(flow, now, config)
    return false if flow.empty?

    eligible?(flow, now, config)
  end

  private_class_method :dispatchable, :dispatchable?, :priority_ring
end
