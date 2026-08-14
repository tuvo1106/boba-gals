require_relative "golden_helper"
require "fileutils"

# Byte-identical dispatch sequences from fixed seeds (docs/testing.md).
#
# These assert nothing about *what the right answer is* — the property specs in
# `scheduler_spec.rb` do that. They assert that the answer has not moved. The
# two are complementary: a property spec catches a violated rule, a golden
# catches the reorder nobody thought to write a rule about.
#
# The scenarios below are chosen so that each one puts a different part of §6
# on the critical path. A change to aging should not be able to pass by leaving
# the mixed-day fixture untouched.
RSpec.describe "Scheduler golden dispatch sequences" do
  # The ordinary case: §10.3's size mix and menu spread over a busy stretch.
  it "matches on a mixed day" do
    flows = golden_flows(seed: 1, orders: 20)

    expect_golden("mixed_day", golden_run(flows))
  end

  # The case §2 exists for. A 14-drink order lands among singles, and the whole
  # fairness claim is about what happens next.
  it "matches when a catering order lands among singles" do
    flows = golden_flows(seed: 7, orders: 24, spacing: 20)

    expect_golden("catering_among_singles", golden_run(flows))
  end

  # §6.2's anti-starvation guarantee is a function of the clock, so this is the
  # fixture that moves if aging is retuned or its multiplier is capped.
  it "matches when aging has to rescue a starved order" do
    flows = golden_flows(seed: 3, orders: 30, spacing: 12)

    expect_golden("aging_rescue", golden_run(flows, stations: 2))
  end

  it "matches with aging switched off" do
    flows = golden_flows(seed: 3, orders: 30, spacing: 12)

    expect_golden("aging_disabled", golden_run(flows, stations: 2, aging_enabled: false))
  end

  # §6.4's priority floor: a remake outranks same-age ordinary work regardless
  # of how long that work has waited.
  it "matches when remakes are in the mix" do
    flows = golden_flows(seed: 11, orders: 20, remake_rate: 25)

    expect_golden("remakes", golden_run(flows))
  end

  # §6.4's floor, isolated.
  #
  # The `remakes` fixture above does *not* pin this: those flows carry the 4x
  # remake multiplier as well, so they already sort first on quantum and the
  # floor is redundant. Deleting the floor left that fixture byte-identical —
  # which is how a golden can look like coverage without being any.
  #
  # This is §6.4's own worked example: a fresh remake against an order that has
  # aged for thirty minutes. `1 + 0.15 x 30 = 5.5` beats the remake's `1 + 4.0
  # = 5.0` on quantum alone, so only the tier puts the remake first.
  it "matches when a fresh remake meets a heavily aged order" do
    aged = Scheduler::Flow.new(
      id: "aged-30min", arrived_at: at(-1800), made_count: 0, total_items: 2,
      promised_at: nil, deficit: 0,
      queue: Array.new(2) { |n| Scheduler::Item.new(id: 10 + n, prep_seconds: 45, enqueued_at: at(-1800), remake: false) }
    )
    fresh_remake = Scheduler::Flow.new(
      id: "remake-fresh", arrived_at: at(0), made_count: 1, total_items: 2,
      promised_at: nil, deficit: 0,
      queue: [ Scheduler::Item.new(id: 20, prep_seconds: 45, enqueued_at: at(0), remake: true) ]
    )
    ordinary = Scheduler::Flow.new(
      id: "ordinary", arrived_at: at(-60), made_count: 0, total_items: 3,
      promised_at: nil, deficit: 0,
      queue: Array.new(3) { |n| Scheduler::Item.new(id: 30 + n, prep_seconds: 70, enqueued_at: at(-60), remake: false) }
    )

    expect_golden("remake_floor", golden_run([ aged, fresh_remake, ordinary ], stations: 1))
  end

  # §6.2's backward scheduling. These flows are ineligible until their promise
  # approaches, so this fixture pins the eligibility boundary.
  it "matches with order-ahead orders in the queue" do
    flows = golden_flows(seed: 5, orders: 18, promised_rate: 30)

    expect_golden("order_ahead", golden_run(flows))
  end

  # Ships disabled (ADR-0014) and is still selectable, so it still needs a
  # fixture — a re-triggered version (issue #31) has to land somewhere.
  #
  # Hand-built rather than generated: every flow `golden_flows` makes starts at
  # `made_count: 0`, so cohesion can never fire and the generated fixture came
  # out byte-identical to `mixed_day`. A fixture that cannot differ from another
  # fixture is not pinning anything.
  it "matches with cohesion enabled" do
    half_made = Scheduler::Flow.new(
      id: "half-made", arrived_at: at(0), made_count: 2, total_items: 4,
      promised_at: nil, deficit: 0, first_ready_at: at(0),
      queue: Array.new(2) { |n| Scheduler::Item.new(id: 40 + n, prep_seconds: 70, enqueued_at: at(0), remake: false) }
    )
    untouched = Scheduler::Flow.new(
      id: "untouched", arrived_at: at(0), made_count: 0, total_items: 4,
      promised_at: nil, deficit: 0,
      queue: Array.new(4) { |n| Scheduler::Item.new(id: 50 + n, prep_seconds: 70, enqueued_at: at(0), remake: false) }
    )
    solo = Scheduler::Flow.new(
      id: "solo", arrived_at: at(0), made_count: 0, total_items: 1,
      promised_at: nil, deficit: 0,
      queue: [ Scheduler::Item.new(id: 60, prep_seconds: 45, enqueued_at: at(0), remake: false) ]
    )
    # §6.4's motivating case, and the reason the threshold is `> 1` rather than
    # `> 2`: the small order whose first drink is already sitting and melting.
    pair = Scheduler::Flow.new(
      id: "pair", arrived_at: at(0), made_count: 1, total_items: 2,
      promised_at: nil, deficit: 0, first_ready_at: at(0),
      queue: [ Scheduler::Item.new(id: 70, prep_seconds: 45, enqueued_at: at(0), remake: false) ]
    )

    expect_golden("cohesion_enabled",
                  golden_run([ untouched, half_made, solo, pair ], stations: 1, cohesion_enabled: true))
  end

  # The same three orders with cohesion off, so the pair of fixtures is the
  # difference the flag makes rather than two unrelated sequences.
  it "matches with cohesion disabled" do
    half_made = Scheduler::Flow.new(
      id: "half-made", arrived_at: at(0), made_count: 2, total_items: 4,
      promised_at: nil, deficit: 0, first_ready_at: at(0),
      queue: Array.new(2) { |n| Scheduler::Item.new(id: 40 + n, prep_seconds: 70, enqueued_at: at(0), remake: false) }
    )
    untouched = Scheduler::Flow.new(
      id: "untouched", arrived_at: at(0), made_count: 0, total_items: 4,
      promised_at: nil, deficit: 0,
      queue: Array.new(4) { |n| Scheduler::Item.new(id: 50 + n, prep_seconds: 70, enqueued_at: at(0), remake: false) }
    )
    solo = Scheduler::Flow.new(
      id: "solo", arrived_at: at(0), made_count: 0, total_items: 1,
      promised_at: nil, deficit: 0,
      queue: [ Scheduler::Item.new(id: 60, prep_seconds: 45, enqueued_at: at(0), remake: false) ]
    )
    pair = Scheduler::Flow.new(
      id: "pair", arrived_at: at(0), made_count: 1, total_items: 2,
      promised_at: nil, deficit: 0, first_ready_at: at(0),
      queue: [ Scheduler::Item.new(id: 70, prep_seconds: 45, enqueued_at: at(0), remake: false) ]
    )

    expect_golden("cohesion_disabled",
                  golden_run([ untouched, half_made, solo, pair ], stations: 1, cohesion_enabled: false))
  end

  # §6.3's control arm. The fairness claim is measured against this, so it has
  # to be as pinned as DRR is.
  it "matches under FIFO" do
    flows = golden_flows(seed: 1, orders: 20)

    expect_golden("fifo", golden_run(flows, policy: :fifo))
  end

  # Every order identical and simultaneous. Nothing distinguishes them but the
  # ring's own ordering, so this is the fixture that moves if a tie-break or a
  # sort's stability changes — the failure a property spec is least likely to
  # have a rule for (ADR-0009).
  it "matches when nothing distinguishes the orders" do
    flows = Array.new(6) do |i|
      queue = Array.new(3) do |n|
        Scheduler::Item.new(id: (i + 1) * 100 + n, prep_seconds: 60, enqueued_at: at(0), remake: false)
      end

      Scheduler::Flow.new(id: format("tie-%02d", i + 1), arrived_at: at(0), queue: queue,
                          made_count: 0, total_items: 3, promised_at: nil, deficit: 0)
    end

    expect_golden("ties", golden_run(flows))
  end

  # A single station serialises every decision, so the sequence *is* the
  # scheduler's preference order with no parallelism hiding disagreements.
  it "matches on one station, where the sequence is the whole preference order" do
    flows = golden_flows(seed: 2, orders: 12)

    expect_golden("single_station", golden_run(flows, stations: 1))
  end
end
