require "rails_helper"

RSpec.describe ThrottleOrderLookups do
  let(:ip) { "203.0.113.5" }

  it "is not exceeded before any failures are recorded" do
    expect(described_class.exceeded?(ip)).to be false
  end

  # These assert the **budget**, not the predicate in isolation, and the
  # distinction is what let an off-by-one through. `OrderChannel#subscribed`
  # checks `exceeded?` *before* recording, so with a strict `>` the check at
  # count == LIMIT passed, that lookup was allowed and recorded, and the budget
  # was LIMIT + 1. The old examples ("not exceeded at exactly the limit") were
  # true of the predicate and wrong about the thing the class documents: parity
  # with Rack::Attack's `status/ip`, which blocks the 61st.
  it "allows exactly LIMIT failed lookups, matching the REST throttle" do
    allowed = 0

    (described_class::LIMIT * 2).times do
      break if described_class.exceeded?(ip)

      described_class.record_failure(ip)
      allowed += 1
    end

    expect(allowed).to eq(described_class::LIMIT)
  end

  it "blocks once the limit has been reached" do
    described_class::LIMIT.times { described_class.record_failure(ip) }

    expect(described_class.exceeded?(ip)).to be true
  end

  it "still allows the last lookup inside the budget" do
    (described_class::LIMIT - 1).times { described_class.record_failure(ip) }

    expect(described_class.exceeded?(ip)).to be false
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
