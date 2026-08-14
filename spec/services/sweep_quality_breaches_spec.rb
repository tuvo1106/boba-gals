require "rails_helper"

RSpec.describe SweepQualityBreaches do
  let(:store) { create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 300 }) }
  let(:menu_item) { create(:menu_item, store: store) }

  # A finished drink whose order is still `partially_ready` — waiting on a
  # sibling — is the only case this ever flags (ADR-0024): the order can't
  # have been handed over yet, so "still sitting" is a fact, not a guess.
  def finished_with_sibling_still_making(seconds_ago, order: nil)
    order ||= create(:order, store: store, status: "partially_ready")
    finished = create(:order_item, order: order, menu_item: menu_item, sequence: 1,
                                   status: "finished", started_at: (seconds_ago + 90).seconds.ago,
                                   finished_at: seconds_ago.seconds.ago)
    create(:order_item, order: order, menu_item: menu_item, sequence: 2, status: "in_progress")
    finished
  end

  # Same shape, for a size other than the 2-drink default above — one finished
  # drink sitting, `size - 1` siblings still making, so the order lands in
  # whichever size class `size` maps to (§9.6, #80).
  def order_with_size(size, seconds_ago:, store: self.store)
    order = create(:order, store: store, status: "partially_ready")
    finished = create(:order_item, order: order, menu_item: menu_item, sequence: 1,
                                   status: "finished", started_at: (seconds_ago + 90).seconds.ago,
                                   finished_at: seconds_ago.seconds.ago)
    (size - 1).times { |i| create(:order_item, order: order, menu_item: menu_item, sequence: i + 2, status: "in_progress") }
    finished
  end

  # §9.6, #80: a 2-drink order is "1-2" class, seeded at 0.5x quality_limit_seconds
  # (150s here) until a confident QualitySpreadStat exists — see the size-aware
  # describe block below for 3-6 and 7+.
  it "logs a breach for a drink that has sat finished past its size class's limit" do
    item = finished_with_sibling_still_making(151)

    breached = described_class.call(store)

    expect(breached).to eq([ item ])
    event = SchedulerEvent.find_by(order_item: item, event_type: "quality_breach")
    expect(event).to be_present
    expect(event.payload["seconds_over"]).to be_within(2).of(1)
  end

  it "does not flag a drink still within its size class's limit" do
    finished_with_sibling_still_making(149)

    expect(described_class.call(store)).to eq([])
  end

  # Once the last sibling finishes, the order reaches `ready` and whether the
  # earlier drink is still sitting or already collected is unknowable without
  # a pickup signal (ADR-0005) — kiosk/web pickup delays (§10.3) are usually
  # under the quality limit, so flagging here would mostly be measuring how
  # fast people walk up, not how long a drink actually sat.
  it "does not flag a drink whose order has already reached ready" do
    order = create(:order, store: store, status: "ready")
    item = create(:order_item, order: order, menu_item: menu_item, sequence: 1,
                               status: "finished", started_at: 400.seconds.ago, finished_at: 310.seconds.ago)
    create(:order_item, order: order, menu_item: menu_item, sequence: 2,
                        status: "finished", started_at: 300.seconds.ago, finished_at: 10.seconds.ago)

    expect(described_class.call(store)).to eq([])
    expect(SchedulerEvent.find_by(order_item: item, event_type: "quality_breach")).to be_nil
  end

  # §9.6: one breach per drink, not one per tick — a periodic sweep must not
  # re-log the same stale drink every 30 seconds forever.
  it "logs a drink only once across repeated runs" do
    finished_with_sibling_still_making(151)

    described_class.call(store)
    second_run = described_class.call(store)

    expect(second_run).to eq([])
    expect(SchedulerEvent.where(event_type: "quality_breach").count).to eq(1)
  end

  it "ignores a drink that was never finished" do
    order = create(:order, store: store, status: "partially_ready")
    create(:order_item, order: order, menu_item: menu_item, status: "in_progress", started_at: 400.seconds.ago)

    expect(described_class.call(store)).to eq([])
  end

  # The flat config key stays meaningful as a scaling knob (#80) rather than
  # being read directly: a tighter store still gets a proportionally tighter
  # seeded threshold for every size class, not just one flat number.
  it "scales the seeded threshold from the store's own quality_limit_seconds" do
    tight_store = create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 30 })
    order = create(:order, store: tight_store, status: "partially_ready")
    item = finished_with_sibling_still_making(16, order: order)

    expect(described_class.call(tight_store)).to eq([ item ])
  end

  # #80: the flat 300s default treats a multi-drink order's ordinary spread as
  # an outlier, since ADR-0014 measured it running several times that at p90.
  describe "size-aware seeded defaults (#80, QualitySpreadStat::SEEDED_MULTIPLIERS)" do
    it "does not flag a 6-drink order still well within its own, larger, seeded limit" do
      # "3-6" seeds at 6.0x -> 1800s here. 1000s is past the flat 300s default
      # but nowhere near this class's own limit.
      order_with_size(6, seconds_ago: 1_000)

      expect(described_class.call(store)).to eq([])
    end

    it "flags a 6-drink order past its own, larger, seeded limit" do
      item = order_with_size(6, seconds_ago: 1_801)

      expect(described_class.call(store)).to eq([ item ])
    end

    it "flags a 7+ order only past its own, much larger, seeded limit" do
      # "7+" seeds at 20.0x -> 6000s here.
      order_with_size(7, seconds_ago: 5_000)
      expect(described_class.call(store)).to eq([])

      item = order_with_size(7, seconds_ago: 6_001)
      expect(described_class.call(store)).to eq([ item ])
    end
  end

  describe "once a size class has a confident learned threshold (#80)" do
    it "uses the learned threshold instead of the seeded multiplier" do
      # threshold_seconds = 1200 + 1.28*sqrt(400) = 1225.6 — well below the
      # "1-2" seeded default of 150s, so this only flags if the learned value
      # is actually the one being read.
      create(:quality_spread_stat, :confident, store: store, size_class: "1-2",
             ewma_seconds: 1_200.0, ewma_variance: 400.0)

      order_with_size(2, seconds_ago: 1_200)
      expect(described_class.call(store)).to eq([])

      item = order_with_size(2, seconds_ago: 1_226)
      expect(described_class.call(store)).to eq([ item ])
    end

    it "ignores an unconfident stat and keeps using the seeded multiplier" do
      create(:quality_spread_stat, store: store, size_class: "1-2",
             ewma_seconds: 10_000.0, ewma_variance: 0.0, sample_count: 1)

      # Still governed by the 150s seeded default, not the unconfident 10,000s
      # EWMA — otherwise a single early sample could suppress every breach.
      item = finished_with_sibling_still_making(151)

      expect(described_class.call(store)).to eq([ item ])
    end
  end

  # The end-to-end version of ADR-0035, driven through the real recorder rather
  # than a factory, because the bug was that the *learner* fed the sweep a
  # threshold no assertion about the sweep alone could have caught.
  #
  # Before the fix this flagged the pair after five seconds: ten solo orders
  # drove the "1-2" EWMA to ~0, `threshold_seconds` to microseconds, and
  # `overdue?` was true the instant the pair's first drink finished.
  describe "solo orders must not poison the 1-2 threshold (ADR-0035)" do
    it "leaves a healthy pair alone after a morning of single-drink orders" do
      QualitySpreadStat::MINIMUM_SAMPLES.times do
        solo = create(:order, store: store, status: "ready",
                              first_ready_at: Time.current, ready_at: Time.current)
        create(:order_item, order: solo, menu_item: menu_item, status: "finished")
        RecordQualitySpread.new.call(solo)
      end

      expect(described_class.call(store)).to eq([]),
        "a 2-drink order was flagged five seconds after its first drink finished"
    end

    before do
      order = create(:order, store: store, status: "partially_ready")
      create(:order_item, order: order, menu_item: menu_item, sequence: 1,
                          status: "finished", started_at: 65.seconds.ago, finished_at: 5.seconds.ago)
      create(:order_item, order: order, menu_item: menu_item, sequence: 2, status: "in_progress")
    end
  end
end
