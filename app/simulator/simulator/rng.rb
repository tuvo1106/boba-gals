require "digest"

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
      @streams = {}
    end

    # An independent substream, so a draw about one entity is unaffected by how
    # many draws anything else has made (DESIGN.md §17, "common random numbers").
    #
    # This is what makes an A/B honest. With a single generator, changing the
    # scheduler changes the *order* in which remakes and pickups are drawn, the
    # streams desynchronise on the first reordered dispatch, and the two runs
    # face different demand — measured at seed 7, only 105 of 740 shared drinks
    # kept the same prep time between DRR and FIFO. Keyed by entity, drink
    # `32-0` draws the same prep time no matter when, or whether, it is made.
    #
    # SHA-256 rather than `String#hash`: Ruby randomises that per process, which
    # would make a seed reproducible only within a single boot.
    #
    # @param purpose [Symbol] which concern is drawing — `:drink`, `:pickup`, …
    # @param key [Object, nil] the entity, usually an order or drink id
    # @return [Simulator::Rng]
    def stream(purpose, key = nil)
      @streams[[ purpose, key ]] ||= Rng.new(derive(purpose, key))
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

    private

    # 64 bits off the digest is ample — `Random.new` accepts an arbitrary
    # integer, and collisions between substreams would only matter at a scale no
    # scenario reaches.
    def derive(purpose, key)
      Digest::SHA256.digest("#{@seed}:#{purpose}:#{key}").unpack1("Q>")
    end
  end
end
