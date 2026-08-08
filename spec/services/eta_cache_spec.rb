require "rails_helper"

RSpec.describe EtaCache do
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

  it "round-trips estimates with integer order ids" do
    described_class.write(store, 7 => 120, 9 => 240)

    expect(described_class.read(store)).to eq(7 => 120, 9 => 240)
  end

  it "reads nothing when cold" do
    expect(described_class.read(store)).to be_nil
  end

  # The first board render after a deploy has no entry and still owes a number.
  describe ".fetch" do
    it "projects inline and warms the cache when cold" do
      order = queue(3)

      expect(described_class.fetch(store)).to include(order.id => be_positive)
      expect(described_class.read(store)).to be_present
    end

    it "reads the cache rather than projecting when warm" do
      queue
      described_class.write(store, 1 => 999)

      expect(ProjectEta).not_to receive(:for_open_orders)
      expect(described_class.fetch(store)).to eq(1 => 999)
    end
  end

  # A malformed entry is not worth failing a board render over — the board is
  # the most visible surface in the shop, and the next recompute overwrites it.
  it "treats an unparseable entry as cold rather than raising" do
    BobaGals::REDIS.with { |redis| redis.set(BobaGals.redis_key("eta", store.id), "not json") }

    expect(described_class.read(store)).to be_nil
  end

  # `web` runs two replicas (§14.2). A per-process cache means two pods showing
  # two different boards, which reads to staff as the board being broken.
  it "stores the entry in Redis, not in process memory" do
    described_class.write(store, 1 => 60)

    raw = BobaGals::REDIS.with { |redis| redis.get(BobaGals.redis_key("eta", store.id)) }
    expect(JSON.parse(raw)).to eq("1" => 60)
  end

  it "expires the entry so a dead worker shows stale numbers for seconds, not a shift" do
    described_class.write(store, 1 => 60)

    ttl = BobaGals::REDIS.with { |redis| redis.ttl(BobaGals.redis_key("eta", store.id)) }
    expect(ttl).to be_between(1, described_class::TTL.to_i)
  end

  # Longer than §7.2's 30s idle tick, so a healthy store always has a warm entry
  # and the cold-start projection stays genuinely exceptional.
  it "outlives the idle tick that keeps it warm" do
    expect(described_class::TTL).to be > 30.seconds
  end
end
