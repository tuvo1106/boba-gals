require "rails_helper"

RSpec.describe ClaimNextDrink do
  let(:store) { create(:store) }
  let(:station) { create(:station, store: store) }
  let(:barista) { create(:barista, store: store) }
  let(:menu_item) { create(:menu_item, store: store) }

  def queue_drink(queued_at: Time.current, order: create(:order, store: store))
    create(:order_item, order: order, menu_item: menu_item, queued_at: queued_at)
  end

  describe "FIFO selection (build step 2)" do
    it "claims the oldest queued drink" do
      newer = queue_drink(queued_at: 1.minute.ago)
      older = queue_drink(queued_at: 5.minutes.ago)

      expect(described_class.new.call(station: station, barista: barista)).to eq(older)
      expect(newer.reload.status).to eq("queued")
    end

    it "assigns the station, barista, and start time" do
      queue_drink

      item = described_class.new.call(station: station, barista: barista)

      expect(item).to have_attributes(status: "in_progress", station: station, barista: barista)
      expect(item.started_at).to be_present
    end

    it "returns nil rather than raising when nothing is queued" do
      expect(described_class.new.call(station: station, barista: barista)).to be_nil
    end

    it "ignores drinks belonging to another store" do
      other = create(:store)
      create(:order_item, order: create(:order, store: other), menu_item: create(:menu_item, store: other))

      expect(described_class.new.call(station: station, barista: barista)).to be_nil
    end

    it "ignores drinks already in progress" do
      create(:order_item, :in_progress, order: create(:order, store: store), menu_item: menu_item)

      expect(described_class.new.call(station: station, barista: barista)).to be_nil
    end
  end

  describe "order status rollup" do
    it "moves the order to in_progress when its first drink is claimed" do
      order = create(:order, store: store, status: "placed")
      queue_drink(order: order)

      described_class.new.call(station: station, barista: barista)

      expect(order.reload.status).to eq("in_progress")
    end
  end

  describe "audit trail" do
    it "records an item_started event" do
      queue_drink

      expect { described_class.new.call(station: station, barista: barista) }
        .to change { SchedulerEvent.where(event_type: "item_started").count }.by(1)
    end
  end

  # §11: "N threads calling ClaimNextDrink simultaneously → every drink claimed
  # exactly once, zero duplicates, zero errors surfaced to the client."
  #
  # Transactional fixtures are disabled here on purpose: they wrap every example
  # in a single connection's transaction, which hides FOR UPDATE SKIP LOCKED
  # entirely. This test is worthless without real concurrent connections.
  describe "concurrent claims (§8, §11)", :no_transaction do
    let!(:persistent_store) { create(:store) }
    let!(:stations) { Array.new(4) { create(:station, store: persistent_store) } }
    let!(:baristas) { Array.new(4) { create(:barista, store: persistent_store) } }

    it "hands every drink to exactly one station, with no duplicates and no errors" do
      item = create(:menu_item, store: persistent_store)
      order = create(:order, store: persistent_store)
      10.times { create(:order_item, order: order, menu_item: item) }

      barrier = Concurrent::CyclicBarrier.new(4)
      errors = Concurrent::Array.new
      claimed = Concurrent::Array.new

      threads = 4.times.map do |i|
        Thread.new do
          barrier.wait
          3.times do
            result = described_class.new.call(station: stations[i], barista: baristas[i])
            claimed << result.id if result
          rescue StandardError => e
            errors << e
          ensure
            ActiveRecord::Base.connection_pool.release_connection
          end
        end
      end
      threads.each(&:join)

      expect(errors).to be_empty, "no error may reach the barista — the second tap gets the next drink (§8)"
      expect(claimed.size).to eq(10), "every drink should have been claimed"
      expect(claimed.uniq.size).to eq(claimed.size), "a drink was handed to two stations"
      expect(OrderItem.where(status: "in_progress").count).to eq(10)
    end
  end
end
