# Deliberately does NOT load Rails — there is no Rails here to load.
#
# That used to be a convention held up by this file choosing not to require
# `rails_helper`. It is now a property of the package: the gemspec declares zero
# runtime dependencies, so the scheduler *cannot* reach for ActiveRecord or
# ActiveSupport without someone adding a dependency on purpose (ADR-0033).
#
# It also keeps these specs in milliseconds, which matters: they are the ones
# `mutant` runs hundreds of times over (ADR-0002).
GEM_ROOT = File.expand_path("..", __dir__)

# Only when this suite is being run *as itself*, from the gem root.
#
# Run from the repo root instead (`bundle exec rspec gems/deficit_scheduler/spec`,
# or mutant, which invokes rspec from there), the repo's own `.rspec` has already
# loaded the application's `spec/spec_helper.rb` and started SimpleCov with
# `SimpleCov.root` at the repo root. Starting a second time here does not scope
# anything to this gem — it re-points the *existing* run and applies
# `minimum_coverage 100` to the whole application, which then fails at ~7%.
#
# Guarded on the working directory rather than on a "has SimpleCov started"
# probe because this is the actual intent: the gem's strict gate belongs to the
# gem's own suite. From anywhere else, the application's 90% gate is the right
# one and this file should keep out of its way.
unless ENV["COVERAGE"] == "0" || Dir.pwd != GEM_ROOT
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch
    skip "/spec/"

    # 100% line **and** branch, enforced by SimpleCov's own built-in minimum.
    #
    # The app's root suite needs a hand-rolled `at_exit` hook for this, because
    # SimpleCov has no *per-directory* minimum and the scheduler was one strict
    # directory inside a 90% project. Here the whole package is the strict part,
    # so the built-in does the job — and unlike the hook it cannot pass
    # vacuously when it matches nothing.
    minimum_coverage line: 100, branch: 100
  end
end

require "deficit_scheduler"

# Builders that keep the examples about scheduling rather than about setup.
module SchedulerBuilders
  # A fixed epoch. Times are relative to it so failures read as "+90s", not as a
  # wall-clock timestamp nobody can hold in their head.
  T0 = Time.utc(2026, 8, 8, 12, 0, 0)

  def at(seconds)
    T0 + seconds
  end

  def item(cost: 60, id: nil, enqueued_at: T0, expedited: false)
    @item_seq = (@item_seq || 0) + 1

    DeficitScheduler::Item.new(
      id: id || @item_seq,
      cost: cost,
      enqueued_at: enqueued_at,
      expedited: expedited
    )
  end

  # @param items [Integer] how many undispatched items the flow has
  def flow(id:, arrived_at: T0, items: 1, cost: 60, total_items: nil,
           deadline: nil, deficit: 0, expedited: false, first_output_at: nil)
    queue = Array.new(items) do
      item(cost: cost, enqueued_at: arrived_at, expedited: expedited)
    end

    DeficitScheduler::Flow.new(
      id: id, arrived_at: arrived_at, queue: queue,
      total_items: total_items, deadline: deadline, deficit: deficit,
      first_output_at: first_output_at
    )
  end

  def state(flows, **config)
    DeficitScheduler::State.new(flows: flows, config: DeficitScheduler::Config.new(**config))
  end

  # Drains the scheduler, returning the flow ids in dispatch sequence. Bounded
  # so a bug cannot hang the suite.
  def dispatch_all(state, now: T0, limit: 500)
    sequence = []

    limit.times do
      picked = DeficitScheduler.pick_next(state, now)
      break if picked.nil?

      sequence << picked[:flow].id
    end

    sequence
  end
end

RSpec.configure do |config|
  # Scoped rather than global, and the reason predates the extraction: included
  # everywhere, `item` collides with `subject(:item)` in the application's
  # `spec/models/order_item_spec.rb`, and every shoulda matcher there starts
  # asserting against a scheduler Item. The two suites do not share a process
  # and the collision is not obvious enough to rediscover cheaply.
  config.include SchedulerBuilders, absolute_file_path: %r{/gems/deficit_scheduler/spec/}
end
