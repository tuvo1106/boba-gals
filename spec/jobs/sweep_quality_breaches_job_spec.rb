require "rails_helper"

RSpec.describe SweepQualityBreachesJob do
  let(:store) { create(:store, :with_stations, scheduler_config: { "quality_limit_seconds" => 300 }) }
  let(:menu_item) { create(:menu_item, store: store) }

  def stale_order
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, status: "finished",
                        started_at: 400.seconds.ago, finished_at: 301.seconds.ago)
    order
  end

  it "logs a breach for a drink that has gone stale" do
    stale_order

    described_class.perform_now

    expect(SchedulerEvent.where(event_type: "quality_breach").count).to eq(1)
  end

  # The marker (§9.4) only reaches the KDS if the queue is rebroadcast — a
  # breach that never triggers KitchenBroadcast is invisible until the next
  # unrelated transition, which could be minutes away.
  it "broadcasts the kitchen queue when a store gets a new breach" do
    order = stale_order
    other_item = create(:order_item, order: order, menu_item: menu_item, status: "queued", sequence: 2)

    payload = nil
    allow(ActionCable.server).to receive(:broadcast) { |_stream, message| payload = message }

    described_class.perform_now

    expect(payload).to be_present
    expect(payload[:next_up].find { |c| c[:id] == other_item.id }).to include(quality_breach: true)
  end

  it "does not broadcast a store with nothing newly breached" do
    store

    expect(ActionCable.server).not_to receive(:broadcast)

    described_class.perform_now
  end
end
