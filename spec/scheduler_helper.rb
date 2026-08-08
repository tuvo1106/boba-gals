require "spec_helper"

# Deliberately does NOT load Rails.
#
# `app/scheduler/**` must not require Rails to load (CLAUDE.md, §6.2) — that is
# what lets the simulator run the production scheduler unmodified (§10.1). If
# this file ever needs `rails_helper`, something in the scheduler has reached for
# ActiveRecord or the clock and the constraint has already been broken.
#
# It also keeps these specs in milliseconds, which matters: they are the ones
# that will be run hundreds of times over by `mutant` (ADR-0002).
root = File.expand_path("../app/scheduler", __dir__)

require "#{root}/scheduler/config"
require "#{root}/scheduler/item"
require "#{root}/scheduler/flow"
require "#{root}/scheduler/state"
require "#{root}/scheduler"

# Builders that keep the examples about scheduling rather than about setup.
module SchedulerBuilders
  # A fixed epoch. Times are relative to it so failures read as "+90s", not as a
  # wall-clock timestamp nobody can hold in their head.
  T0 = Time.utc(2026, 8, 8, 12, 0, 0)

  def at(seconds)
    T0 + seconds
  end

  def item(prep_seconds: 60, id: nil, enqueued_at: T0, remake: false)
    @item_seq = (@item_seq || 0) + 1

    Scheduler::Item.new(
      id: id || @item_seq,
      prep_seconds: prep_seconds,
      enqueued_at: enqueued_at,
      remake: remake
    )
  end

  # @param drinks [Integer] how many undispatched drinks the order has
  def flow(id:, arrived_at: T0, drinks: 1, prep_seconds: 60, made_count: 0,
           total_items: nil, promised_at: nil, deficit: 0, remake: false)
    queue = Array.new(drinks) do
      item(prep_seconds: prep_seconds, enqueued_at: arrived_at, remake: remake)
    end

    Scheduler::Flow.new(
      id: id, arrived_at: arrived_at, queue: queue, made_count: made_count,
      total_items: total_items, promised_at: promised_at, deficit: deficit
    )
  end

  def state(flows, **config)
    Scheduler::State.new(flows: flows, config: Scheduler::Config.new(**config))
  end

  # Drains the scheduler, returning the order ids in dispatch sequence. Bounded
  # so a bug cannot hang the suite.
  def dispatch_all(state, now: T0, limit: 500)
    sequence = []

    limit.times do
      picked = Scheduler.pick_next(state, now)
      break if picked.nil?

      sequence << picked[:flow].id
    end

    sequence
  end
end

RSpec.configure do |config|
  # Scoped to spec/scheduler/ deliberately. Included globally, `item` collides
  # with `subject(:item)` in spec/models/order_item_spec.rb and every shoulda
  # matcher there starts asserting against a Scheduler::Item.
  config.include SchedulerBuilders, file_path: %r{/spec/scheduler/}
end
