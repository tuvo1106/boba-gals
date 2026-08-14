module Scheduler
  # Scheduler tuning (DESIGN.md §6.6).
  #
  # Carries only what `pick_next` reads. `stores.scheduler_config` holds two more
  # keys — `quality_limit_seconds` and `eta_safety_factor` — which belong to the
  # quality timer (§9.6) and the ETA projection (§7.1); the scheduler must not
  # grow opinions about either.
  class Config
    # §6.3. `drr` and `fifo` are selectable on a store; `rr` and `sjf` exist for
    # the simulator's comparison arms and are rejected by `UpdateSchedulerConfig`
    # — SJF starves large orders by construction, which is the failure §1 exists
    # to prevent.
    POLICIES = %i[drr fifo rr sjf].freeze

    DEFAULTS = {
      policy: :drr,
      quantum: 60,
      aging_enabled: true,
      aging_rate: 0.15,
      cohesion_enabled: false,
      cohesion_boost: 1.0,
      remake_multiplier: 4.0,
      promise_buffer: 120
    }.freeze

    attr_reader(*DEFAULTS.keys)

    # @param overrides [Hash] any subset of DEFAULTS
    def initialize(**overrides)
      DEFAULTS.merge(overrides).each { |key, value| instance_variable_set(:"@#{key}", value) }
    end

    # Builds from `stores.scheduler_config`, which has string keys and carries
    # keys the scheduler ignores.
    #
    # @param hash [Hash] the store's effective scheduler config
    # @return [Scheduler::Config]
    def self.from_store(hash)
      attrs = hash.to_h.filter_map do |key, value|
        symbol = key.to_sym
        next unless DEFAULTS.key?(symbol)

        [ symbol, symbol == :policy ? value.to_sym : value ]
      end

      new(**attrs.to_h)
    end

    # @return [Boolean] whether the §6.3 control arm is selected
    def fifo?
      policy == :fifo
    end

    # @return [Boolean] true unless a §6.3 comparison arm has replaced it
    def drr?
      policy == :drr
    end

    # @raise [ArgumentError] on a policy `pick_next` has no branch for. Silently
    #   falling back to DRR would make a mis-typed sweep look like a null result
    #   rather than a mistake.
    def validate!
      return self if POLICIES.include?(policy)

      raise ArgumentError, "unknown policy #{policy.inspect}; expected one of #{POLICIES.join(', ')}"
    end
  end
end
