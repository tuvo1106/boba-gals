require "rails_helper"

RSpec.describe OrderBroadcast do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  def order_with_drink(**attrs)
    order = create(:order, store: store, **attrs)
    create(:order_item, order: order, menu_item: menu_item)
    order
  end

  describe "the leading edge" do
    it "broadcasts an open order to the customer watching it" do
      order = order_with_drink

      expect { described_class.call(store) }
        .to have_broadcasted_to(described_class.stream_name(order))
        .with { |payload| expect(payload["status"]).to eq("placed") }
    end

    # One stream per code, not per store: a customer's screen must not receive —
    # and so must not be trusted to filter out — anybody else's order.
    it "gives each order its own stream" do
      mine = order_with_drink(customer_first_name: "Sam")
      theirs = order_with_drink(customer_first_name: "Cleo")

      expect { described_class.call(store) }
        .to have_broadcasted_to(described_class.stream_name(mine))
        .with { |payload| expect(payload["pickup_code"]).to eq(mine.pickup_code) }

      expect(described_class.stream_name(theirs)).not_to eq(described_class.stream_name(mine))
    end

    # `pickup_code` is unique per store per day (§13.1), not globally, so two
    # shops will hand out the same code on the same afternoon (§16).
    it "scopes the stream to the store, not to the code alone" do
      other_store = create(:store, :with_stations)
      mine = create(:order, store: store, pickup_code: "A1B2")
      theirs = create(:order, store: other_store, pickup_code: "A1B2")

      expect(described_class.stream_name(mine)).not_to eq(described_class.stream_name(theirs))
    end

    # A terminal order has nothing left to report, and `picked_up` accumulates
    # for the life of the store — fanning out to those means publishing to every
    # order the shop has ever sold, once a second, forever.
    it "does not broadcast to an order that is already done with" do
      collected = order_with_drink(status: "picked_up", picked_up_at: Time.current)

      expect { described_class.call(store) }
        .not_to have_broadcasted_to(described_class.stream_name(collected))
    end

    it "still broadcasts to an order that is ready but uncollected" do
      ready = order_with_drink(status: "ready", ready_at: Time.current)

      expect { described_class.call(store) }
        .to have_broadcasted_to(described_class.stream_name(ready))
    end

    it "does not broadcast another store's orders" do
      other_store = create(:store, :with_stations)
      theirs = create(:order, store: other_store)

      expect { described_class.call(store) }
        .not_to have_broadcasted_to(described_class.stream_name(theirs))
    end
  end

  # Every transition changes the projected ETA of *every* open order, so this is
  # the highest-fanout broadcast in the system — twenty transitions across forty
  # open orders is eight hundred publishes with nothing damping it.
  describe "the 1/sec throttle (§9.2)" do
    it "suppresses a second broadcast inside the same window" do
      order = order_with_drink

      described_class.call(store)

      expect { described_class.call(store) }
        .not_to have_broadcasted_to(described_class.stream_name(order))
    end

    it "throttles each store independently" do
      order_with_drink
      other_store = create(:store, :with_stations)
      theirs = create(:order, store: other_store)
      create(:order_item, order: theirs, menu_item: create(:menu_item, store: other_store))

      described_class.call(store)

      expect { described_class.call(other_store) }
        .to have_broadcasted_to(described_class.stream_name(theirs))
    end

    # "The debounce must be a Redis lock, not in-process state — web pods come
    # in pairs (§14.4)." Two pods with independent in-process windows throttle
    # to 2/sec and neither can see the other's pending flush.
    it "holds the window in Redis rather than in process state" do
      described_class.call(store)

      key = BobaGals.redis_key("order", "throttle", store.id)
      expect(BobaGals::REDIS.with { |redis| redis.get(key) }).to be_present
    end

    it "does not share a window with the board" do
      order = order_with_drink
      BoardBroadcast.call(store)

      expect { described_class.call(store) }
        .to have_broadcasted_to(described_class.stream_name(order))
    end
  end

  # A plain drop loses whichever transition lands last in a burst — and for this
  # view that is the one that says the drink is ready, leaving a customer
  # watching "in progress" for a cup already on the counter.
  describe "the trailing flush" do
    it "schedules a flush for a broadcast that arrived inside the window" do
      order_with_drink
      described_class.call(store)

      expect { described_class.call(store) }
        .to have_enqueued_job(OrderFlushJob).with(store.id)
    end

    it "enqueues one flush for a burst, not one per trigger" do
      order_with_drink
      described_class.call(store)

      expect { 20.times { described_class.call(store) } }
        .to have_enqueued_job(OrderFlushJob).exactly(:once)
    end

    it "publishes unconditionally when it runs" do
      order = order_with_drink
      described_class.call(store)

      expect { described_class.flush(store) }
        .to have_broadcasted_to(described_class.stream_name(order))
    end

    it "clears the pending marker so the next burst can schedule its own flush" do
      order_with_drink
      described_class.call(store)
      described_class.call(store)

      described_class.flush(store)

      pending = BobaGals.redis_key("order", "pending", store.id)
      expect(BobaGals::REDIS.with { |redis| redis.get(pending) }).to be_nil
    end
  end

  # The projection is 175ms at 436 queued drinks (ADR-0012). A broadcast that
  # runs once a second must read the cache, not recompute it.
  it "reads the cached projection rather than running one per broadcast" do
    order = order_with_drink
    EtaCache.write(store, { order.id => 321 })

    expect(ProjectEta).not_to receive(:for_open_orders)

    expect { described_class.call(store) }
      .to have_broadcasted_to(described_class.stream_name(order))
      .with { |payload| expect(payload["eta_seconds"]).to eq(321) }
  end
end
