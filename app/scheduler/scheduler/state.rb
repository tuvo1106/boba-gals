module Scheduler
  # Everything `pick_next` needs, and nothing it doesn't (DESIGN.md §6.2).
  #
  # Rebuilt per dispatch cycle from `order_items WHERE status = 'queued'` — §6.5
  # is explicit that no queue table is materialized. Only `deficit` and `pointer`
  # survive between cycles, in Redis, and losing them costs one round of
  # unfairness rather than correctness.
  class State
    attr_reader :flows, :config
    attr_accessor :pointer

    # @param flows [Array<Scheduler::Flow>] ordered by arrival (§6.5)
    # @param config [Scheduler::Config]
    # @param pointer [Integer] the ring pointer, resumed from Redis
    def initialize(flows:, config: Config.new, pointer: 0)
      @flows = flows
      @config = config
      @pointer = pointer
      @granted_to = nil
    end

    # Which flow has already drawn its quantum for the current visit.
    #
    # Deficit round robin gives each flow **one quantum per round**, then serves
    # as much as that buys. Without tracking this, a flow that empties its
    # deficit simply grants itself another and never yields — with the default
    # 120s quantum against 60s drinks, the first order in the ring drains
    # completely before any other order is touched, which is precisely the
    # behaviour §2 exists to prevent.
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
