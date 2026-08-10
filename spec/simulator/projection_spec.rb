require "simulator_helper"

RSpec.describe Simulator::Projection do
  def drink(id, prep: 60)
    Simulator::Drink.new(id: id, prep_seconds: prep, actual_prep_seconds: prep, remake: false)
  end

  def order(id, drinks, arrived_at: 0.0, promised_at: nil)
    Simulator::Order.new(id: id, arrived_at: arrived_at, items: drinks, promised_at: promised_at)
  end

  def stations(count, busy: [])
    Array.new(count) { |i| { index: i, busy_until: busy[i] } }
  end

  def project(orders, count: 1, now: 0.0, safety: 1.0, target: nil, config: Scheduler::Config.new(aging_enabled: false))
    described_class.new(orders: orders, stations: stations(count), now: now,
                        config: config, safety_factor: safety, target: target)
  end

  describe "§7.1's method" do
    it "spreads queued work across the stations" do
      orders = [ order(1, [ drink("a") ]), order(2, [ drink("b") ]) ]

      expect(project(orders, count: 2).call).to eq(1 => 60.0, 2 => 60.0)
    end

    # "Order ETA = max over its items" — an order is ready when its slowest
    # drink is, not when its first one is.
    it "quotes an order for its last drink, not its first" do
      quotes = project([ order(1, [ drink("a"), drink("b") ]) ], count: 2).call

      expect(quotes.fetch(1)).to eq(60.0)
    end

    it "waits for a busy station rather than assuming every one is free" do
      described = described_class.new(
        orders: [ order(1, [ drink("a") ]) ], stations: stations(1, busy: [ 100.0 ]),
        now: 0.0, config: Scheduler::Config.new, safety_factor: 1.0
      )

      expect(described.call.fetch(1)).to eq(160.0)
    end

    it "applies the safety factor" do
      expect(project([ order(1, [ drink("a") ]) ], safety: 1.5).call.fetch(1)).to eq(90.0)
    end

    # Nominal prep, never the realised time — production quotes from a seeded
    # guess or §7.3's EWMA and cannot see the future. The gap between the two is
    # what §10.4's ETA error measures.
    it "quotes from nominal prep time, not what the drink will really take" do
      slow = Simulator::Drink.new(id: "a", prep_seconds: 60, actual_prep_seconds: 300, remake: false)

      expect(project([ order(1, [ slow ]) ]).call.fetch(1)).to eq(60.0)
    end
  end

  # §6.2 schedules a promise backward, so `pick_next` refuses to dispatch it and
  # it never reaches the loop. Without handling, it falls out of the projection
  # and quotes zero — the same defect fixed in `ProjectEta#order_ahead`, and the
  # reason both files carry the same guard.
  describe "order-ahead" do
    it "quotes a promised order for when it was promised, not zero" do
      ahead = order(1, [ drink("a") ], promised_at: 7200.0)

      expect(project([ ahead ]).call.fetch(1)).to eq(7200.0)
    end

    it "does not pad a promised time with the safety factor" do
      ahead = order(1, [ drink("a") ], promised_at: 3600.0)

      expect(project([ ahead ], safety: 1.5).call.fetch(1)).to eq(3600.0)
    end

    it "still quotes the walk-up behind it for its own work only" do
      ahead = order(1, [ drink("a"), drink("b") ], promised_at: 7200.0)
      walk_up = order(2, [ drink("c") ])

      expect(project([ ahead, walk_up ]).call.fetch(2)).to eq(60.0)
    end
  end

  # Stopping once the quoted order's drinks are all placed cannot change its
  # answer, and at saturation it is the difference between a projection and a
  # hang. Asserted as equality with the full projection rather than by timing.
  describe "the target early exit" do
    it "returns exactly what the full projection would" do
      orders = (1..40).map { |i| order(i, [ drink("#{i}a"), drink("#{i}b") ], arrived_at: i.to_f) }

      full = project(orders, count: 3).call

      orders.each do |o|
        expect(project(orders, count: 3, target: o.id).call.fetch(o.id))
          .to eq(full.fetch(o.id)), "quote for order #{o.id} changed when targeted"
      end
    end
  end

  describe "the horizon (§10.3)" do
    # A queue deep enough that the far end lands past the hour.
    let(:swamped) { (1..200).map { |i| order(i, [ drink("#{i}a", prep: 300) ], arrived_at: i.to_f) } }

    it "stops projecting past the horizon" do
      projection = project(swamped)
      projection.call

      expect(projection).to be_capped
    end

    # The bug this replaces was `fetch(id, 0)` answering for an order the
    # projection never reached. A capped quote is a floor, and a floor is not
    # zero.
    it "floors an unreached order at the horizon rather than quoting zero" do
      quotes = project(swamped).call

      # Everyone gets an answer and nobody gets zero — that default is the bug
      # this exists to prevent. The orders the loop never reached are the ones
      # sitting exactly at the horizon; the rest were really projected, and a
      # drink dispatched just inside the horizon legitimately finishes past it.
      expect(quotes.keys).to match_array(swamped.map(&:id))
      expect(quotes.values).to all(be_positive)
      expect(quotes.values.count(described_class::HORIZON_SECONDS)).to be > 100
    end

    it "does not cap a queue that fits inside the horizon" do
      projection = project([ order(1, [ drink("a") ]) ])
      projection.call

      expect(projection).not_to be_capped
    end
  end

  # `pick_next` mutates what it is given — deficits, the ring pointer, and the
  # flow queues themselves (§6.2). A quote that consumed the real queue would
  # reorder what the kitchen makes next.
  describe "isolation from the caller's state" do
    it "leaves the orders it was handed untouched" do
      orders = [ order(1, [ drink("a"), drink("b") ]) ]

      project(orders).call

      expect(orders.first.items.size).to eq(2)
      expect(orders.first.items.map(&:started_at)).to all(be_nil)
    end

    it "is repeatable" do
      orders = [ order(1, [ drink("a") ]), order(2, [ drink("b"), drink("c") ]) ]
      projection = project(orders, count: 2)

      expect(projection.call).to eq(project(orders, count: 2).call)
    end
  end
end
