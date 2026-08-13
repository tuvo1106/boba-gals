require "rails_helper"

RSpec.describe SweepQualityBreaches do
  let(:store) { create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 300 }) }
  let(:menu_item) { create(:menu_item, store: store) }

  def finished(seconds_ago, order: create(:order, store: store))
    create(:order_item, order: order, menu_item: menu_item,
                        status: "finished", started_at: (seconds_ago + 90).seconds.ago,
                        finished_at: seconds_ago.seconds.ago)
  end

  it "logs a breach for a drink that has sat finished past the quality limit" do
    item = finished(301)

    breached = described_class.call(store)

    expect(breached).to eq([ item ])
    event = SchedulerEvent.find_by(order_item: item, event_type: "quality_breach")
    expect(event).to be_present
    expect(event.payload["seconds_over"]).to be_within(2).of(1)
  end

  it "does not flag a drink still within the limit" do
    finished(299)

    expect(described_class.call(store)).to eq([])
  end

  # §9.6: one breach per drink, not one per tick — a periodic sweep must not
  # re-log the same stale drink every 30 seconds forever.
  it "logs a drink only once across repeated runs" do
    finished(301)

    described_class.call(store)
    second_run = described_class.call(store)

    expect(second_run).to eq([])
    expect(SchedulerEvent.where(event_type: "quality_breach").count).to eq(1)
  end

  it "ignores a drink that was never finished" do
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, status: "in_progress", started_at: 400.seconds.ago)

    expect(described_class.call(store)).to eq([])
  end

  it "uses the store's own quality_limit_seconds rather than the default" do
    tight_store = create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 30 })
    item = finished(31, order: create(:order, store: tight_store))

    expect(described_class.call(tight_store)).to eq([ item ])
  end
end
