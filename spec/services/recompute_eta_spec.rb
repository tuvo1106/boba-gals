require "rails_helper"

RSpec.describe RecomputeEta do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def queue(count = 2)
    order = create(:order, store: store)
    count.times do |i|
      create(:order_item, order: order, menu_item: menu_item, prep_seconds: 60,
                          queued_at: 1.minute.ago, sequence: i + 1)
    end
    order
  end

  # §7.2: "debounced to at most one run per store per 2 seconds". The debounce
  # is what keeps a burst of transitions from running a projection that costs
  # 175ms at 436 queued drinks (ADR-0012's sort, measured) once per transition.
  describe "the 2-second debounce (§7.2)" do
    it "recomputes on the first trigger in a window" do
      queue

      expect { described_class.call(store) }.to change { EtaCache.read(store) }.from(nil)
    end

    it "does not recompute again inside the same window" do
      queue
      described_class.call(store)

      expect(ProjectEta).not_to receive(:for_open_orders)
      described_class.call(store)
    end

    # A plain drop loses whichever trigger lands last in a burst, and that is
    # the one describing what the shop looks like now — the customer would see a
    # mid-burst ETA until the 30s tick corrected it.
    it "schedules a trailing recompute for triggers inside the window" do
      queue
      described_class.call(store)

      expect { described_class.call(store) }
        .to have_enqueued_job(RecomputeEtaJob).with(store.id)
    end

    it "enqueues one trailing recompute for a burst, not one per trigger" do
      queue
      described_class.call(store)

      expect { 20.times { described_class.call(store) } }
        .to have_enqueued_job(RecomputeEtaJob).exactly(:once)
    end

    # "The debounce must be a Redis lock, not in-process state — web pods come
    # in pairs (§14.4)." Two pods with independent in-process windows debounce
    # to two runs per window and neither can see the other's pending flush.
    it "holds the window in Redis rather than in process state" do
      queue
      described_class.call(store)

      key = BobaGals.redis_key("eta", "throttle", store.id)
      expect(BobaGals::REDIS.with { |redis| redis.get(key) }).to be_present
      expect(BobaGals::REDIS.with { |redis| redis.pttl(key) }).to be <= described_class::WINDOW.in_milliseconds
    end

    it "recomputes again once the window has expired" do
      queue
      described_class.call(store)
      BobaGals::REDIS.with { |redis| redis.del(BobaGals.redis_key("eta", "throttle", store.id)) }

      expect(ProjectEta).to receive(:for_open_orders).and_return({})
      described_class.call(store)
    end
  end

  describe ".flush" do
    it "recomputes unconditionally, because the window was closed when it was queued" do
      queue
      described_class.call(store)

      expect(ProjectEta).to receive(:for_open_orders).and_call_original
      described_class.flush(store)
    end

    it "clears the pending marker so the next burst can schedule its own flush" do
      queue
      described_class.call(store)
      described_class.call(store)

      described_class.flush(store)

      pending = BobaGals.redis_key("eta", "pending", store.id)
      expect(BobaGals::REDIS.with { |redis| redis.get(pending) }).to be_nil
    end
  end

  describe "what a recompute produces" do
    it "caches the projection so the board reads rather than recomputes" do
      order = queue(3)

      described_class.call(store)

      expect(EtaCache.read(store)).to include(order.id => be_positive)
    end

    it "pushes the board" do
      queue

      expect(BoardBroadcast).to receive(:call).with(store)
      described_class.call(store)
    end
  end
end
