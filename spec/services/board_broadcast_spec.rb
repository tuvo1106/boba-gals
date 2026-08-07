require "rails_helper"

RSpec.describe BoardBroadcast do
  let(:store) { create(:store, :with_stations) }
  let(:stream) { described_class.stream_name(store) }

  describe "the leading edge" do
    it "broadcasts the current board immediately" do
      expect { described_class.call(store) }.to have_broadcasted_to(stream)
    end

    it "sends a whole snapshot, not a delta (§9.2)" do
      order = create(:order, store: store, customer_first_name: "Sarah")
      create(:order_item, order: order, menu_item: create(:menu_item, store: store))

      expect { described_class.call(store) }
        .to have_broadcasted_to(stream)
        .with { |payload| expect(payload["making"].first["first_name"]).to eq("Sarah") }
    end

    it "streams per store, so one shop's board never shows another's" do
      other = create(:store, :with_stations)

      expect { described_class.call(store) }
        .not_to have_broadcasted_to(described_class.stream_name(other))
    end
  end

  # §9.2 throttles board broadcasts to 1/sec. The window lives in Redis, not in
  # a class variable, because two `web` pods with independent in-process windows
  # throttle to 2/sec and neither can see the other's pending flush (§14.4).
  describe "the throttle" do
    it "suppresses a second broadcast inside the same window" do
      described_class.call(store)

      expect { described_class.call(store) }.not_to have_broadcasted_to(stream)
    end

    it "throttles each store independently" do
      other = create(:store, :with_stations)
      described_class.call(store)

      expect { described_class.call(other) }
        .to have_broadcasted_to(described_class.stream_name(other))
    end

    # The window has to expire on its own. Asserting the TTL rather than
    # sleeping through it (docs/testing.md): a key written without one would
    # suppress the board permanently the first time a process died mid-call.
    it "gives the window a TTL so a crash cannot wedge the board shut" do
      described_class.call(store)

      ttl = BobaGals::REDIS.with { |redis| redis.pttl(BobaGals.redis_key("board", "throttle", store.id)) }

      expect(ttl).to be_between(1, BoardBroadcast::WINDOW.in_milliseconds)
    end

    it "opens again once the window has passed" do
      described_class.call(store)
      BobaGals::REDIS.with { |redis| redis.del(BobaGals.redis_key("board", "throttle", store.id)) }

      expect { described_class.call(store) }.to have_broadcasted_to(stream)
    end
  end

  # A plain drop loses whichever transition happens to be last in a burst, and
  # that is the one people are looking at — a name would sit in Making after its
  # drink was already handed over.
  describe "the trailing flush" do
    it "schedules a flush when a change lands inside a closed window" do
      described_class.call(store)

      expect { described_class.call(store) }
        .to have_enqueued_job(BoardFlushJob).with(store.id)
    end

    it "schedules one flush for a burst, not one per change" do
      described_class.call(store)

      expect { 20.times { described_class.call(store) } }
        .to have_enqueued_job(BoardFlushJob).exactly(:once)
    end

    it "broadcasts unconditionally when the flush runs" do
      described_class.call(store)

      expect { described_class.flush(store) }.to have_broadcasted_to(stream)
    end

    it "re-arms so the next change can schedule its own flush" do
      described_class.call(store)
      described_class.call(store)
      described_class.flush(store)

      expect { described_class.call(store) }
        .to have_enqueued_job(BoardFlushJob).exactly(:once)
    end
  end

  describe BoardFlushJob do
    it "flushes the store's board" do
      expect { described_class.perform_now(store.id) }
        .to have_broadcasted_to(BoardBroadcast.stream_name(store))
    end

    # A store deleted between enqueue and perform must not crash a worker.
    it "does nothing for a store that no longer exists" do
      expect { described_class.perform_now(-1) }.not_to raise_error
    end
  end
end
