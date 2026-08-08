require "rails_helper"

RSpec.describe RecordPrepTime do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def finished(seconds, item: menu_item)
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: item, prep_seconds: item.base_prep_seconds,
                        status: "finished", started_at: seconds.seconds.ago, finished_at: Time.current)
  end

  def record(seconds, item: menu_item)
    described_class.new.call(finished(seconds, item: item))
  end

  describe "learning (§7.3)" do
    # Blending the first observation against a nil average would make its weight
    # depend on the seeded guess, which is the thing being replaced.
    it "seeds the average with the first observation rather than the guess" do
      stat = record(90)

      expect(stat.ewma_seconds).to be_within(0.01).of(90)
      expect(stat.sample_count).to eq(1)
    end

    # §7.3: new = 0.2 * observed + 0.8 * old.
    it "moves the average by alpha on each later sample" do
      record(100)
      stat = record(200)

      expect(stat.ewma_seconds).to be_within(0.01).of((0.2 * 200) + (0.8 * 100))
    end

    it "converges toward a changed reality rather than averaging over all history" do
      record(60)
      20.times { record(120) }

      expect(described_class.new.call(finished(120)).ewma_seconds).to be_within(1).of(120)
    end

    it "counts samples so confidence can be judged" do
      3.times { record(60) }

      expect(PrepTimeStat.find_by(menu_item: menu_item).sample_count).to eq(3)
    end

    it "keeps one stat per menu item" do
      other = create(:menu_item, store: store, base_prep_seconds: 95)
      record(60)
      record(300, item: other)

      expect(PrepTimeStat.count).to eq(2)
      expect(PrepTimeStat.find_by(menu_item: other).ewma_seconds).to be_within(0.01).of(300)
    end
  end

  # §7.3: "Discard samples outside [0.25x, 4x] of current EWMA — those are a
  # barista who forgot to tap 'finish', not a slow drink."
  describe "the outlier guard (§7.3)" do
    it "ignores a drink left open for twenty minutes" do
      record(60)
      before = PrepTimeStat.find_by(menu_item: menu_item).ewma_seconds

      record(1_200)

      stat = PrepTimeStat.find_by(menu_item: menu_item)
      expect(stat.ewma_seconds).to eq(before)
      expect(stat.sample_count).to eq(1), "a rejected sample must not count toward confidence"
    end

    it "ignores an implausibly fast tap" do
      record(60)

      record(5)

      expect(PrepTimeStat.find_by(menu_item: menu_item).ewma_seconds).to be_within(0.01).of(60)
    end

    it "accepts a sample at the edge of the band" do
      record(100)

      expect(record(400).sample_count).to eq(2)
    end

    it "rejects a sample just outside it" do
      record(100)

      expect(record(401).sample_count).to eq(1)
    end

    # The band tracks the learned value, not the seed — otherwise it would keep
    # rejecting reality once the shop genuinely got faster or slower.
    it "moves the band with the average as it learns" do
      record(100)
      10.times { record(300) }
      learned = PrepTimeStat.find_by(menu_item: menu_item).ewma_seconds

      expect(learned).to be > 250
      expect(record(900).sample_count).to eq(12), "900s is inside 4x of the learned value"
    end

    it "has nothing to be an outlier from on the first sample" do
      expect(record(3_600).sample_count).to eq(1)
    end
  end

  describe "what is not an observation" do
    it "ignores a drink that was never started" do
      order = create(:order, store: store)
      item = create(:order_item, order: order, menu_item: menu_item, prep_seconds: 60,
                                 status: "finished", started_at: nil, finished_at: Time.current)

      expect(described_class.new.call(item)).to be_nil
      expect(PrepTimeStat.count).to be_zero
    end

    it "ignores a drink that was never finished" do
      order = create(:order, store: store)
      item = create(:order_item, order: order, menu_item: menu_item, prep_seconds: 60,
                                 status: "in_progress", started_at: 1.minute.ago, finished_at: nil)

      expect(described_class.new.call(item)).to be_nil
    end

    it "ignores a clock that ran backwards" do
      order = create(:order, store: store)
      item = create(:order_item, order: order, menu_item: menu_item, prep_seconds: 60,
                                 status: "finished", started_at: Time.current, finished_at: 1.minute.ago)

      expect(described_class.new.call(item)).to be_nil
    end
  end

  # §7.1's safety factor is one blunt multiplier over every item. Knowing which
  # drinks are erratic rather than merely slow is what would let it stop being
  # one (§7.3, §10.4).
  describe "variance" do
    it "stays near zero for a consistent drink" do
      10.times { record(60) }

      expect(PrepTimeStat.find_by(menu_item: menu_item).ewma_variance).to be < 1
    end

    it "rises for an erratic one" do
      steady = create(:menu_item, store: store, base_prep_seconds: 60)
      10.times { record(60, item: steady) }
      [ 40, 130, 45, 150, 50, 140, 60, 120, 45, 135 ].each { |s| record(s) }

      erratic = PrepTimeStat.find_by(menu_item: menu_item).ewma_variance
      expect(erratic).to be > PrepTimeStat.find_by(menu_item: steady).ewma_variance
    end
  end
end
