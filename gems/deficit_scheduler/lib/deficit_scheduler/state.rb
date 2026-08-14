module DeficitScheduler
  # Everything `pick_next` needs, and nothing it doesn't.
  #
  # Designed to be rebuilt from scratch each dispatch cycle rather than
  # materialized as a queue table. Only `deficit` and `pointer` are worth
  # carrying between cycles, and losing them costs one round of unfairness
  # rather than correctness — so a consumer can persist them cheaply, or not at
  # all.
  class State
    attr_reader :flows, :config
    attr_accessor :pointer

    # @param flows [Array<DeficitScheduler::Flow>] ordered by arrival, which is
    #   what makes the ring's tiebreak stable across rebuilds
    # @param config [DeficitScheduler::Config]
    # @param pointer [Integer] the ring pointer, resumed from wherever the
    #   consumer kept it
    # @param granted_to [Object, nil] the flow id already granted this round.
    #   Round state, and safe to lose for the same reason the deficit is: a
    #   forgotten grant costs one extra quantum.
    def initialize(flows:, config: Config.new, pointer: 0, granted_to: nil)
      @flows = flows
      @config = config
      @pointer = pointer
      @granted_to = granted_to
    end

    # @return [Object, nil]
    attr_reader :granted_to

    # Which flow has already drawn its quantum for the current visit.
    #
    # Deficit round robin gives each flow **one quantum per round**, then serves
    # as much as that buys. Without tracking this, a flow that empties its
    # deficit simply grants itself another and never yields — with a quantum
    # larger than the head item's cost, the first flow in the ring drains
    # completely before any other is touched, which is precisely the behaviour
    # the algorithm exists to prevent.
    #
    # @return [Boolean]
    def granted?(flow)
      @granted_to == flow.id
    end

    def grant!(flow)
      @granted_to = flow.id
    end

    # Moves to the next flow, ending the current one's visit.
    def advance!
      @pointer += 1
      @granted_to = nil
    end
  end
end
