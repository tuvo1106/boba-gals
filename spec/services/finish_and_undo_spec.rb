require "rails_helper"

RSpec.describe "finishing and undoing drinks" do
  let(:store) { create(:store) }
  let(:order) { create(:order, store: store, status: "in_progress") }

  def working_drink(**attrs)
    create(:order_item, :in_progress, order: order, **attrs)
  end

  describe FinishDrink do
    it "marks the drink finished and stamps the time" do
      item = working_drink

      result = described_class.new.call(item)

      expect(result).to be_success
      expect(item.reload).to have_attributes(status: "finished")
      expect(item.finished_at).to be_present
    end

    it "refuses a drink that was never started" do
      item = create(:order_item, order: order)

      expect(described_class.new.call(item)).not_to be_success
    end

    it "records the observed duration, which the EWMA will need at step 7 (§7.3)" do
      item = working_drink(started_at: 90.seconds.ago)

      described_class.new.call(item)

      event = SchedulerEvent.find_by(event_type: "item_finished", order_item: item)
      expect(event.payload["observed_seconds"]).to be_within(2).of(90)
    end

    describe "order rollup (§5.1)" do
      it "moves a part-finished order to partially_ready" do
        working_drink
        second = working_drink
        described_class.new.call(second)

        expect(order.reload.status).to eq("partially_ready")
      end

      it "moves the order to ready once every drink is done" do
        first = working_drink
        second = working_drink

        described_class.new.call(first)
        described_class.new.call(second)

        expect(order.reload).to have_attributes(status: "ready")
        expect(order.ready_at).to be_present
      end

      # first_ready_at anchors the quality timer and the cohesion spread
      # metric — how long the earliest drink sat while the rest were made
      # (§9.6, §10.4).
      it "stamps first_ready_at on the first finished drink and never moves it" do
        first = working_drink
        second = working_drink

        described_class.new.call(first)
        original = order.reload.first_ready_at

        travel_to(2.minutes.from_now) { described_class.new.call(second) }

        expect(order.reload.first_ready_at).to eq(original)
      end

      it "records an order_ready event when the last drink lands" do
        item = working_drink

        expect { described_class.new.call(item) }
          .to change { SchedulerEvent.where(event_type: "order_ready").count }.by(1)
      end
    end
  end

  describe UndoLastAction do
    # Undo corrects a mistap, not a drink (§5.2). A drink genuinely made and
    # wrong is a remake, which is build step 8.
    it "returns a finished drink to in_progress inside the window" do
      item = working_drink
      FinishDrink.new.call(item)

      result = described_class.new.call(item.reload)

      expect(result).to be_success
      expect(item.reload).to have_attributes(status: "in_progress", finished_at: nil)
    end

    it "returns an in-progress drink to queued and releases the station" do
      item = working_drink

      described_class.new.call(item)

      expect(item.reload).to have_attributes(
        status: "queued", station_id: nil, barista_id: nil, started_at: nil
      )
    end

    it "refuses once the 60-second window has passed" do
      item = working_drink
      FinishDrink.new.call(item)

      result = travel_to(61.seconds.from_now) { described_class.new.call(item.reload) }

      expect(result).not_to be_success
      expect(result.error).to match(/window has passed/)
    end

    it "refuses a queued drink, which has nothing to undo" do
      expect(described_class.new.call(create(:order_item, order: order))).not_to be_success
    end

    # An undone finish must move the order back out of ready, or the board keeps
    # telling a customer their drink is waiting for them (§5.2).
    it "moves the order back from ready to partially_ready" do
      first = working_drink
      second = working_drink
      FinishDrink.new.call(first)
      FinishDrink.new.call(second)
      expect(order.reload.status).to eq("ready")

      described_class.new.call(second.reload)

      expect(order.reload).to have_attributes(status: "partially_ready", ready_at: nil)
    end
  end
end
