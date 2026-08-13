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

  it "logs a breach for a drink that has sat finished past the quality limit" do
    item = finished_with_sibling_still_making(301)

    breached = described_class.call(store)

    expect(breached).to eq([ item ])
    event = SchedulerEvent.find_by(order_item: item, event_type: "quality_breach")
    expect(event).to be_present
    expect(event.payload["seconds_over"]).to be_within(2).of(1)
  end

  it "does not flag a drink still within the limit" do
    finished_with_sibling_still_making(299)

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
    finished_with_sibling_still_making(301)

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

  it "uses the store's own quality_limit_seconds rather than the default" do
    tight_store = create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 30 })
    order = create(:order, store: tight_store, status: "partially_ready")
    item = finished_with_sibling_still_making(31, order: order)

    expect(described_class.call(tight_store)).to eq([ item ])
  end
end
