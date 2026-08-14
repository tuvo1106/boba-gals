require "rails_helper"

# The delay is what implements the same undo-safety RecordPrepTimeJob has
# (ADR-0019) — an EWMA can't be cleanly un-blended, so nothing is learned
# until there is nothing left to undo. The end-to-end behaviour lives in
# spec/services/finish_and_undo_spec.rb; this file drives the job directly,
# at states FinishDrink cannot easily produce.
RSpec.describe RecordQualitySpreadJob do
  let(:store) { create(:store, :with_stations) }

  def ready_order(**attrs)
    first_ready = 5.minutes.ago
    order = create(:order, store: store, status: "ready", first_ready_at: first_ready,
                          ready_at: first_ready + 300, **attrs)
    2.times { |i| create(:order_item, order: order, menu_item: create(:menu_item, store: store), sequence: i + 1, status: "finished") }
    order
  end

  it "records the sample when ready_at is still the one it was enqueued for" do
    order = ready_order

    described_class.perform_now(order.id, order.ready_at)

    expect(QualitySpreadStat.find_by(store: store, size_class: "1-2").ewma_seconds)
      .to be_within(2).of(300)
  end

  # The undo already reverted status/ready_at, so there is nothing to learn from.
  it "records nothing when the ready transition was undone" do
    order = ready_order
    ready_at = order.ready_at
    order.update!(status: "partially_ready", ready_at: nil)

    expect { described_class.perform_now(order.id, ready_at) }.not_to change(QualitySpreadStat, :count)
  end

  # An undo plus a re-finish enqueues two jobs and both see a `ready` order.
  # Only the one carrying the surviving stamp may record, or one order teaches
  # the baseline twice.
  it "records nothing for a ready transition that was superseded by a later one" do
    order = ready_order
    superseded = order.ready_at - 10.seconds

    expect { described_class.perform_now(order.id, superseded) }.not_to change(QualitySpreadStat, :count)
  end

  it "records nothing when the order is no longer ready at all" do
    order = ready_order
    ready_at = order.ready_at
    order.update!(status: "partially_ready")

    expect { described_class.perform_now(order.id, ready_at) }.not_to change(QualitySpreadStat, :count)
  end

  it "shrugs off an order that no longer exists" do
    expect { described_class.perform_now(-1, Time.current) }.not_to raise_error
  end
end
