require "rails_helper"

# The delay is what implements §5.2's "discard the prep-time sample" (ADR-0019),
# so these are the guards that keep a phantom duration out of the EWMA. The
# end-to-end behaviour lives in `spec/services/finish_and_undo_spec.rb`; this
# file drives the job directly, at states `FinishDrink` cannot easily produce.
RSpec.describe RecordPrepTimeJob do
  let(:store) { create(:store) }
  let(:order) { create(:order, store: store, status: "in_progress") }

  def finished_drink(**attrs)
    create(:order_item, :finished, order: order, **attrs)
  end

  it "records the sample when the finish is still the one it was enqueued for" do
    item = finished_drink

    described_class.perform_now(item.id, item.finished_at)

    expect(PrepTimeStat.find_by(menu_item_id: item.menu_item_id).ewma_seconds)
      .to be_within(2).of(90)
  end

  # The undo already reverted the status, so there is nothing to learn from.
  it "records nothing when the finish was undone" do
    item = finished_drink
    finish = item.finished_at
    item.update!(status: "in_progress", finished_at: nil)

    expect { described_class.perform_now(item.id, finish) }.not_to change(PrepTimeStat, :count)
  end

  # An undo plus a re-finish enqueues two jobs and both see a `finished` item.
  # Only the one carrying the surviving stamp may record, or one drink teaches
  # the board twice.
  it "records nothing for a finish that was superseded by a later one" do
    item = finished_drink
    superseded = item.finished_at - 10.seconds

    expect { described_class.perform_now(item.id, superseded) }.not_to change(PrepTimeStat, :count)
  end

  # A drink that was failed and remade is a different row (§5.2); this one was
  # never finished, so its duration measures how long it took to go wrong.
  it "records nothing when the item is no longer finished at all" do
    item = finished_drink
    finish = item.finished_at
    item.update!(status: "failed")

    expect { described_class.perform_now(item.id, finish) }.not_to change(PrepTimeStat, :count)
  end

  it "shrugs off an item that no longer exists" do
    expect { described_class.perform_now(-1, Time.current) }.not_to raise_error
  end
end
