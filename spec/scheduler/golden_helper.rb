require "scheduler_helper"

# Support for the golden dispatch sequences (docs/testing.md).
#
# A golden test pins the *whole* output rather than a property someone thought
# to assert: a fixed scenario in, a byte-identical dispatch sequence out. It is
# what catches a refactor that quietly reorders two dispatches or flips a
# tie-break while every property spec still passes.
#
# **A diff in a golden file is a behaviour change.** Justify it in the PR body
# or revert it. Never regenerate one to make a red build green — that converts
# the whole mechanism into an expensive no-op.
#
# To regenerate deliberately:
#
#     REGENERATE_GOLDEN=1 bin/rspec spec/scheduler/golden_spec.rb
#
module GoldenSupport
  # Constant lookup is lexical, so `T0` inside this module would not find
  # `SchedulerBuilders::T0` even though both are included into the example.
  T0 = SchedulerBuilders::T0

  DIR = File.expand_path("golden", __dir__)

  # A 64-bit LCG, so a scenario is a pure function of its seed.
  #
  # Deliberately *not* `Random.new(seed)`. Ruby's Mersenne Twister is stable in
  # practice, but these fixtures are meant to still match in two years and on
  # whatever Ruby ships then — and a golden file that drifts because the stdlib
  # changed is worse than no golden file, because the first response to the diff
  # will be to regenerate it. Constants are Knuth's MMIX.
  class Lcg
    def initialize(seed)
      @state = (seed * 2_862_933_555_777_941_757 + 3_037_000_493) & 0xFFFF_FFFF_FFFF_FFFF
    end

    # @return [Integer] in 0...n
    def int(n)
      @state = (@state * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407) & 0xFFFF_FFFF_FFFF_FFFF

      # High bits, because an LCG's low bits have short periods.
      (@state >> 33) % n
    end

    # @param weighted [Array<Array>] `[[value, weight], ...]`
    def pick(weighted)
      total = weighted.sum { |(_, w)| w }
      roll = int(total)

      weighted.each do |value, weight|
        return value if roll < weight

        roll -= weight
      end

      weighted.last.first
    end
  end

  # The §6.1 menu spread. A menu where everything costs the same would hide the
  # problem the scheduler exists to solve, so the golden scenarios must not use
  # uniform drinks.
  MENU = [ [ 40, 3 ], [ 45, 4 ], [ 70, 2 ], [ 95, 2 ] ].freeze

  # §10.3's heavy tail: most orders are small, and the catering order that DRR
  # exists for has to actually appear.
  SIZES = [ [ 1, 62 ], [ 2, 22 ], [ 3, 9 ], [ 5, 4 ], [ 14, 3 ] ].freeze

  # Builds a deterministic set of flows.
  #
  # @param seed [Integer]
  # @param orders [Integer] how many orders arrive
  # @param spacing [Integer] mean seconds between arrivals
  # @return [Array<Scheduler::Flow>]
  def golden_flows(seed:, orders:, spacing: 45, remake_rate: 0, promised_rate: 0)
    rng = Lcg.new(seed)
    arrived = 0

    Array.new(orders) do |i|
      arrived += rng.int(spacing * 2)
      size = rng.pick(SIZES)
      remake = remake_rate.positive? && rng.int(100) < remake_rate
      promised = promised_rate.positive? && rng.int(100) < promised_rate

      queue = Array.new(size) do |n|
        Scheduler::Item.new(
          id: (i + 1) * 100 + n,
          prep_seconds: rng.pick(MENU),
          enqueued_at: T0 + arrived,
          remake: remake
        )
      end

      Scheduler::Flow.new(
        id: format("order-%02d", i + 1),
        arrived_at: T0 + arrived,
        queue: queue,
        made_count: 0,
        total_items: size,
        promised_at: promised ? T0 + arrived + 3600 : nil,
        deficit: 0
      )
    end
  end

  # Drains the scheduler across `stations`, advancing the clock the way the shop
  # actually would: the next decision happens when a station frees up.
  #
  # Time advancing is the point. A golden that dispatched everything at T0 would
  # never exercise aging (§6.2), which is the one part of the scheduler whose
  # behaviour is a function of the clock.
  #
  # The state is rebuilt from the flows that have *arrived* on every decision,
  # which is what §6.5 does in production — the flow set comes from
  # `order_items WHERE status = 'queued'`, and a drink cannot be queued before
  # its order exists. Deficits live on the Flow objects and the ring pointer is
  # carried across, exactly as Redis carries them between calls.
  #
  # Handing the scheduler a flow that has not arrived yet gives `quantum_for` a
  # negative waiting time, hence a negative quantum, hence a deficit that can
  # never reach the head drink — the ring then spins until §6.2's livelock guard
  # trips. Unreachable in production for the reason above; see the PR body.
  #
  # @return [String] the sequence, one dispatch per line
  def golden_run(flows, stations: 3, limit: 400, **config)
    config = Scheduler::Config.new(**config)
    free_at = Array.new(stations, 0)
    pointer = 0
    lines = []

    limit.times do
      station = free_at.each_with_index.min_by { |seconds, index| [ seconds, index ] }.last
      now = T0 + free_at[station]

      present = flows.select { |flow| flow.arrived_at <= now && !flow.empty? }
      state = Scheduler::State.new(flows: present, config: config)
      state.pointer = pointer

      picked = present.empty? ? nil : Scheduler.pick_next(state, now)
      pointer = state.pointer

      # Nothing dispatchable *now* does not mean nothing ever: an order-ahead
      # flow becomes eligible later (§6.2), and a later order has not arrived
      # yet. Jump the idle station forward, giving up once every station has run
      # past the horizon.
      if picked.nil?
        break if free_at.min >= 12 * 3600

        free_at[station] += 30
        next
      end

      item = picked[:item]
      lines << format("t=%05d station=%d %s item=%-5d prep=%3d%s",
                      free_at[station], station, picked[:flow].id, item.id,
                      item.prep_seconds, item.remake? ? " remake" : "")
      free_at[station] += item.prep_seconds
    end

    "#{lines.join("\n")}\n"
  end

  # Compares against the committed fixture, or writes it when regenerating.
  def expect_golden(name, actual)
    path = File.join(DIR, "#{name}.txt")

    if ENV["REGENERATE_GOLDEN"]
      FileUtils.mkdir_p(DIR)
      File.write(path, actual)
      skip "regenerated #{name}.txt — review the diff before committing"
    end

    unless File.exist?(path)
      raise "missing golden fixture #{path}. Generate it with " \
            "REGENERATE_GOLDEN=1 bin/rspec spec/scheduler/golden_spec.rb, then read the diff."
    end

    expect(actual).to eq(File.read(path)),
                      "#{name} dispatch sequence changed. That is a behaviour change: " \
                      "justify it in the PR body, or revert. Do not regenerate to go green."
  end
end

RSpec.configure do |config|
  config.include GoldenSupport, file_path: %r{/spec/scheduler/golden}
end
