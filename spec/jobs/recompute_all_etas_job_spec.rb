require "rails_helper"

RSpec.describe RecomputeAllEtasJob do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def queue(status: "queued")
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, prep_seconds: 60,
                        queued_at: 1.minute.ago, sequence: 1, status: status)
    order
  end

  # §7.2's idle tick exists because nothing else fires while a barista is
  # quietly making a 95-second drink — without it the board's countdown freezes
  # between transitions, and a drink running over its estimate never corrects
  # until it finally lands.
  it "recomputes a store with queued work" do
    queue

    expect { described_class.perform_now }.to change { EtaCache.read(store) }.from(nil)
  end

  it "recomputes a store whose drinks are all already being made" do
    queue(status: "in_progress")

    expect { described_class.perform_now }.to change { EtaCache.read(store) }.from(nil)
  end

  # A closed shop does not need its empty board recomputed twice a minute all
  # night, and the tick runs against every store in the table.
  it "skips a store with nothing open" do
    store

    described_class.perform_now

    expect(EtaCache.read(store)).to be_nil
  end

  it "skips a store whose work is all finished" do
    queue(status: "finished")

    described_class.perform_now

    expect(EtaCache.read(store)).to be_nil
  end
end
