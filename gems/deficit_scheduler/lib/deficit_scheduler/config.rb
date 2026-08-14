module DeficitScheduler
  # Scheduler tuning.
  #
  # Carries only what `pick_next` reads. A consumer's own configuration almost
  # certainly holds more than this — persisted keys, unrelated tuning, its own
  # vocabulary — and translating that down to these keys is the consumer's job,
  # not this class's. `from_h` is the seam for exactly that.
  class Config
    # `drr` is the real policy. `fifo`, `rr` and `sjf` exist as comparison arms
    # for measuring what the deficit actually buys — each removes one thing DRR
    # does, so a benchmark can attribute the difference to it. `sjf` in
    # particular starves large flows by construction and is a bound to measure
    # against, never a setting to ship.
    POLICIES = %i[drr fifo rr sjf].freeze

    DEFAULTS = {
      policy: :drr,
      quantum: 60,
      aging_enabled: true,
      aging_rate: 0.15,
      staleness_enabled: false,
      staleness_boost: 1.0,
      expedited_multiplier: 4.0,
      deadline_buffer: 120
    }.freeze

    attr_reader(*DEFAULTS.keys)

    # @param overrides [Hash] any subset of DEFAULTS
    def initialize(**overrides)
      DEFAULTS.merge(overrides).each { |key, value| instance_variable_set(:"@#{key}", value) }
    end

    # Builds from a loose hash: string or symbol keys, unknown keys dropped.
    #
    # Deliberately forgiving, because the caller is usually deserializing from
    # somewhere — a JSON column, a config file, request params — and will carry
    # keys this class has no business knowing about.
    #
    # @param hash [Hash] keys matching DEFAULTS, as strings or symbols
    # @return [DeficitScheduler::Config]
    def self.from_h(hash)
      attrs = hash.to_h.filter_map do |key, value|
        symbol = key.to_sym
        next unless DEFAULTS.key?(symbol)

        [ symbol, symbol == :policy ? value.to_sym : value ]
      end

      new(**attrs.to_h)
    end

    # @return [Boolean] whether the plain-arrival-order control arm is selected
    def fifo?
      policy == :fifo
    end

    # @return [Boolean] true unless a comparison arm has replaced it
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
