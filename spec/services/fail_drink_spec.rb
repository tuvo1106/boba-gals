require "rails_helper"

RSpec.describe FailDrink do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }
  let(:order) { create(:order, store: store) }

  def making(**attrs)
    create(:order_item, :in_progress, order: order, menu_item: menu_item,
                                      prep_seconds: 60, sequence: 1, **attrs)
  end

  describe "what happens to the drink that went wrong" do
    it "marks it failed" do
      item = making

      described_class.new.call(item, reason: "spill")

      expect(item.reload.status).to eq("failed")
    end

    it "records why, because the reason is queried later" do
      item = making

      described_class.new.call(item, reason: "wrong_order")

      expect(item.reload.remake_reason).to eq("wrong_order")
    end

    # §9.4: "Fail/remake requires a reason tap (spill, wrong order, quality)."
    # Free text here would reach `scheduler_events` and turn a countable metric
    # into a pile of prose.
    it "refuses a reason that is not one of the three" do
      item = making

      result = described_class.new.call(item, reason: "because")

      expect(result).not_to be_success
      expect(item.reload.status).to eq("in_progress")
    end

    it "refuses a drink nobody has started" do
      item = create(:order_item, order: order, menu_item: menu_item, sequence: 1)

      expect(described_class.new.call(item, reason: "spill")).not_to be_success
    end

    # §5.2: `finished` is terminal. A finished drink was genuinely made, its
    # prep-time sample is honest, and un-finishing it would delete both facts.
    it "refuses a drink that is already finished" do
      item = making
      item.update!(status: "finished", finished_at: Time.current)

      result = described_class.new.call(item, reason: "quality")

      expect(result).not_to be_success
      expect(item.reload.status).to eq("finished")
    end
  end

  describe "the replacement drink (§5.2)" do
    it "is a new row rather than a reversal of the old one" do
      item = making

      expect { described_class.new.call(item, reason: "spill") }
        .to change { order.order_items.count }.by(1)
    end

    it "points back at the drink it replaces" do
      item = making

      remake = described_class.new.call(item, reason: "spill").remake

      expect(remake.remake_of).to eq(item)
      expect(remake).to be_remake
    end

    it "is queued and ready to be picked up by the scheduler" do
      item = making

      remake = described_class.new.call(item, reason: "spill").remake

      expect(remake.status).to eq("queued")
      expect(remake.queued_at).to be_present
      expect(remake.station_id).to be_nil
    end

    # §4.1: what the customer ordered is frozen at order time. Editing the menu
    # since must not change the drink being remade.
    it "copies what the customer ordered, not the current menu" do
      item = making(label: "Thai Tea, 50%, Boba pearls",
                    selected_options: [ { "option_id" => 3, "name" => "50%" } ])
      menu_item.update!(name: "Renamed", base_prep_seconds: 999, price_cents: 9999)

      remake = described_class.new.call(item, reason: "spill").remake

      expect(remake.label).to eq("Thai Tea, 50%, Boba pearls")
      expect(remake.prep_seconds).to eq(60)
      expect(remake.selected_options.first["name"]).to eq("50%")
    end

    # `sequence` is what the KDS renders as "2 of 5", so a remake appends rather
    # than displacing a drink already in someone's hand.
    it "goes after every drink already in the order" do
      create(:order_item, order: order, menu_item: menu_item, sequence: 2)
      item = making

      remake = described_class.new.call(item, reason: "spill").remake

      expect(remake.sequence).to eq(3)
    end
  end

  # §7.3 learns from `finished_at - started_at`. A spilled drink was never made,
  # so that duration measures how long it took to go wrong — learning from it
  # would teach the board that spills are how long drinks take.
  it "does not teach the prep-time average from a drink that was never made" do
    item = making

    expect { described_class.new.call(item, reason: "spill") }
      .not_to have_enqueued_job(RecordPrepTimeJob)
  end

  it "logs the remake so it can be counted (§10.4, §15)" do
    item = making

    expect { described_class.new.call(item, reason: "spill") }
      .to change { SchedulerEvent.where(event_type: "item_remade").count }.by(1)

    expect(SchedulerEvent.last.payload).to include("reason" => "spill", "failed_item_id" => item.id)
  end

  describe "what the rest of the shop sees" do
    # The order goes backwards: it had one drink being made and now has one
    # queued again, so an order that was `in_progress` must not read as ready.
    it "re-derives the order's status" do
      item = making
      create(:order_item, :finished, order: order, menu_item: menu_item, sequence: 2)
      RollUpOrderStatus.new.call(order)

      described_class.new.call(item, reason: "spill")

      expect(order.reload.status).to eq("partially_ready")
    end

    it "pushes the kitchen and the board without anyone refreshing" do
      item = making

      expect(BroadcastStoreViews).to receive(:call).with(store)

      described_class.new.call(item, reason: "spill")
    end
  end

  # §6.4's priority floor is carried by the remake existing — the scheduler
  # sorts a flow with a pending remake into the top tier regardless of age.
  # Nothing here says so, and this is what proves the wiring.
  #
  # The scheduler calls this "expedited" rather than "remake" (ADR-0033): it has
  # no idea what a remake is, only that this flow belongs in the priority tier.
  # This assertion is the seam where the shop's word becomes the scheduler's.
  it "gives the order the priority floor without asking for it" do
    item = making

    described_class.new.call(item, reason: "spill")

    flows = SchedulerStateStore.new(store).load.flows

    expect(flows.find { |f| f.id == order.id }).to be_pending_expedited
  end
end
