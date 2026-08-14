require "rails_helper"

RSpec.describe ThrottleOrderLookups do
  let(:ip) { "203.0.113.5" }

  it "is not exceeded before any failures are recorded" do
    expect(described_class.exceeded?(ip)).to be false
  end

  it "is not exceeded at exactly the limit" do
    described_class::LIMIT.times { described_class.record_failure(ip) }

    expect(described_class.exceeded?(ip)).to be false
  end

  it "is exceeded one past the limit" do
    (described_class::LIMIT + 1).times { described_class.record_failure(ip) }

    expect(described_class.exceeded?(ip)).to be true
  end

  it "tracks each IP independently" do
    (described_class::LIMIT + 1).times { described_class.record_failure(ip) }

    expect(described_class.exceeded?("198.51.100.9")).to be false
  end

  # `web` runs two pods (§14.2) — an in-process counter would let each pod grant
  # its own budget, same reasoning as ThrottledBroadcast.
  it "stores the count in Redis, not in process memory" do
    described_class.record_failure(ip)

    raw = BobaGals::REDIS.with { |redis| redis.get(BobaGals.redis_key("order_channel", "failed_lookups", ip)) }
    expect(raw.to_i).to eq(1)
  end

  it "expires the count so a quiet minute resets the budget" do
    described_class.record_failure(ip)

    ttl = BobaGals::REDIS.with { |redis| redis.ttl(BobaGals.redis_key("order_channel", "failed_lookups", ip)) }
    expect(ttl).to be_between(1, described_class::PERIOD.to_i)
  end
end
