module Simulator
  # Every random draw in the simulator, from one seeded source (DESIGN.md §10.2).
  #
  # "Seed the RNG and surface the seed in the UI. Reproducible bad days are the
  # entire point." A run is a pure function of its seed, so a surprising result
  # can be replayed exactly rather than described.
  class Rng
    attr_reader :seed

    def initialize(seed)
      @seed = seed
      @random = Random.new(seed)
    end

    # @return [Float] uniform in [0, 1)
    def uniform
      @random.rand
    end

    # @return [Float] uniform in [low, high)
    def between(low, high)
      low + (@random.rand * (high - low))
    end

    # @return [Boolean]
    def chance(probability)
      @random.rand < probability
    end

    # Box-Muller. Ruby's stdlib has no normal deviate, and the simulator must
    # not depend on a gem for something this small.
    # @return [Float]
    def normal(mean = 0.0, sigma = 1.0)
      u1 = 1.0 - @random.rand
      u2 = @random.rand

      mean + (sigma * Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2))
    end

    # §10.3: prep times are lognormal, not normal. "Drinks occasionally go
    # wrong; they never go faster than possible." A normal distribution has a
    # left tail that would produce drinks made in negative time.
    #
    # @param median [Numeric] the item's mean prep time
    # @param sigma [Float] shape; §10.3 default 0.28
    # @return [Float] seconds, always positive
    def lognormal(median, sigma)
      median * Math.exp(normal(0.0, sigma))
    end

    # @return [Float] seconds until the next event
    def exponential(mean)
      -mean * Math.log(1.0 - @random.rand)
    end

    # @param weighted [Hash{Object => Numeric}] value => relative weight
    # @return [Object]
    def categorical(weighted)
      total = weighted.values.sum
      target = @random.rand * total

      cumulative = 0.0
      weighted.each do |value, weight|
        cumulative += weight
        return value if target < cumulative
      end

      weighted.keys.last
    end
  end
end
