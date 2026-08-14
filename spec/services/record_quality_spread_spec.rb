require "rails_helper"

RSpec.describe RecordQualitySpread do
  let(:store) { create(:store, :with_stations) }

  # first_ready_at and ready_at are already stamped by RollUpOrderStatus for
  # exactly this purpose — build the order state directly rather than driving
  # FinishDrink, since that's covered end to end in spec/services/finish_and_undo_spec.rb.
  def ready_order(spread_seconds, size: 2, store: self.store)
    first_ready = (spread_seconds + 60).seconds.ago
    order = create(:order, store: store, status: "ready", first_ready_at: first_ready, ready_at: first_ready + spread_seconds)
    size.times { |i| create(:order_item, order: order, menu_item: create(:menu_item, store: store), sequence: i + 1, status: "finished") }
    order
  end

  def record(spread_seconds, size: 2, store: self.store)
    described_class.new.call(ready_order(spread_seconds, size: size, store: store))
  end

  describe "learning (§9.6, #80)" do
    it "seeds the average with the first observation" do
      stat = record(300, size: 4)

      expect(stat.ewma_seconds).to be_within(0.01).of(300)
      expect(stat.sample_count).to eq(1)
    end

    it "accepts a legitimate zero-spread observation from a single-drink order" do
      stat = record(0, size: 1)

      expect(stat.ewma_seconds).to eq(0.0)
      expect(stat.sample_count).to eq(1)
    end

    # Same formula as RecordPrepTime: new = 0.2 * observed + 0.8 * old.
    it "moves the average by alpha on each later sample" do
      record(1_000, size: 4)
      stat = record(2_000, size: 4)

      expect(stat.ewma_seconds).to be_within(0.01).of((0.2 * 2_000) + (0.8 * 1_000))
    end

    it "keeps one stat per (store, size_class), not per order" do
      record(1_000, size: 4)
      record(1_500, size: 5)

      expect(QualitySpreadStat.where(store: store, size_class: "3-6").count).to eq(1)
    end

    it "keeps separate stats for different size classes" do
      record(150, size: 2)
      record(1_500, size: 4)

      expect(QualitySpreadStat.find_by(store: store, size_class: "1-2").ewma_seconds).to be_within(0.01).of(150)
      expect(QualitySpreadStat.find_by(store: store, size_class: "3-6").ewma_seconds).to be_within(0.01).of(1_500)
    end

    it "keeps separate stats per store" do
      other_store = create(:store, :with_stations)
      record(1_000, size: 4)
      record(5_000, size: 4, store: other_store)

      expect(QualitySpreadStat.find_by(store: store, size_class: "3-6").ewma_seconds).to be_within(0.01).of(1_000)
      expect(QualitySpreadStat.find_by(store: other_store, size_class: "3-6").ewma_seconds).to be_within(0.01).of(5_000)
    end
  end

  # No outlier band, unlike RecordPrepTime — see the class comment for why: no
  # failure mode here is analogous to a barista forgetting to tap "finish",
  # and real spread legitimately spans a wide range by nature (ADR-0014).
  describe "no outlier rejection" do
    it "does not reject a sample far below the current EWMA" do
      record(1_000, size: 4)

      expect(record(10, size: 4).sample_count).to eq(2)
    end

    it "does not reject a sample far above the current EWMA" do
      record(100, size: 4)

      expect(record(10_000, size: 4).sample_count).to eq(2)
    end
  end

  describe "what is not an observation" do
    it "ignores an order with no first_ready_at" do
      order = create(:order, store: store, status: "ready", first_ready_at: nil, ready_at: Time.current)

      expect(described_class.new.call(order)).to be_nil
      expect(QualitySpreadStat.count).to be_zero
    end

    it "ignores an order with no ready_at" do
      order = create(:order, store: store, status: "partially_ready", first_ready_at: 1.minute.ago, ready_at: nil)

      expect(described_class.new.call(order)).to be_nil
    end

    it "ignores a clock that ran backwards" do
      order = create(:order, store: store, status: "ready", first_ready_at: Time.current, ready_at: 1.minute.ago)

      expect(described_class.new.call(order)).to be_nil
    end

    it "ignores an order with no countable items, which has no size class" do
      order = create(:order, store: store, status: "ready", first_ready_at: 1.minute.ago, ready_at: Time.current)

      expect(described_class.new.call(order)).to be_nil
      expect(QualitySpreadStat.count).to be_zero
    end
  end

  describe "variance" do
    it "stays near zero for a consistent spread" do
      10.times { record(300, size: 4) }

      expect(QualitySpreadStat.find_by(store: store, size_class: "3-6").ewma_variance).to be < 1
    end

    it "rises for an erratic one" do
      steady_store = create(:store, :with_stations)
      10.times { record(300, size: 4, store: steady_store) }
      [ 100, 900, 150, 950, 120, 880, 200, 800, 130, 870 ].each { |s| record(s, size: 4) }

      erratic = QualitySpreadStat.find_by(store: store, size_class: "3-6").ewma_variance
      steady = QualitySpreadStat.find_by(store: steady_store, size_class: "3-6").ewma_variance
      expect(erratic).to be > steady
    end
  end
end
