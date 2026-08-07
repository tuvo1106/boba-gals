require "rails_helper"

RSpec.describe PickupCode do
  describe "the alphabet (§13.1)" do
    it "excludes every character people misread off a receipt" do
      expect(described_class::ALPHABET).not_to include(*described_class::AMBIGUOUS)
    end

    # §13.1 says "30-char alphabet ... ≈ 810k codes", but removing seven of the
    # 36 alphanumerics leaves 29, giving 29^4 = 707,281. The exclusion list is
    # the real requirement; this pins the arithmetic that actually follows from
    # it so the discrepancy can't quietly drift further.
    it "has 29 characters, giving a 707,281-code space" do
      expect(described_class::ALPHABET.size).to eq(29)
      expect(described_class::ALPHABET.size**described_class::LENGTH).to eq(707_281)
    end

    it "generates codes of the documented length from that alphabet" do
      100.times do
        code = described_class.generate
        expect(code.length).to eq(4)
        expect(code.chars).to all(satisfy { |c| described_class::ALPHABET.include?(c) })
      end
    end
  end

  describe ".generate_unique" do
    let(:store) { create(:store) }

    it "avoids a code already used by that store today" do
      allow(described_class).to receive(:generate).and_return("AAAA", "AAAA", "BBBB")
      create(:order, store: store, pickup_code: "AAAA", placed_at: Time.current)

      expect(described_class.generate_unique(store: store)).to eq("BBBB")
    end

    # Uniqueness is per store *per day* — the same code is free again tomorrow.
    it "reuses a code from a previous day" do
      allow(described_class).to receive(:generate).and_return("AAAA")
      create(:order, store: store, pickup_code: "AAAA", placed_at: 2.days.ago)

      expect(described_class.generate_unique(store: store)).to eq("AAAA")
    end

    it "does not collide with another store's code" do
      allow(described_class).to receive(:generate).and_return("AAAA")
      create(:order, store: create(:store), pickup_code: "AAAA", placed_at: Time.current)

      expect(described_class.generate_unique(store: store)).to eq("AAAA")
    end

    it "raises rather than looping forever when the space is exhausted" do
      allow(described_class).to receive(:generate).and_return("AAAA")
      create(:order, store: store, pickup_code: "AAAA", placed_at: Time.current)

      expect { described_class.generate_unique(store: store) }
        .to raise_error(described_class::ExhaustedError)
    end
  end
end
