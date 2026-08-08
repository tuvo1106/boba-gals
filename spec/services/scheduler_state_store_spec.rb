require "rails_helper"

RSpec.describe SchedulerStateStore do
  let(:store) { create(:store) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def order_with(drinks:, placed_at: Time.current, **attrs)
    order = create(:order, store: store, placed_at: placed_at, **attrs)
    drinks.times { |i| create(:order_item, order: order, menu_item: menu_item, queued_at: placed_at, sequence: i + 1) }
    order
  end

  describe "#load" do
    # §6.5: no queue table. The flow set is rebuilt from queued items every
    # cycle, so there is only ever one source of truth.
    it "builds one flow per order, ordered by arrival" do
      later = order_with(drinks: 1, placed_at: 1.minute.ago)
      earlier = order_with(drinks: 2, placed_at: 5.minutes.ago)

      state = described_class.new(store).load

      expect(state.flows.map(&:id)).to eq([ earlier.id, later.id ])
      expect(state.flows.first.queue.size).to eq(2)
    end

    it "excludes drinks that are no longer queued" do
      order = order_with(drinks: 1)
      create(:order_item, :in_progress, order: order, menu_item: menu_item)
      create(:order_item, :finished, order: order, menu_item: menu_item)

      expect(described_class.new(store).load.flows.first.queue.size).to eq(1)
    end

    # Cohesion asks how much of the order is *done*, and finished drinks have
    # left the queue — so made_count cannot be derived from it (§6.4).
    it "counts finished drinks for cohesion even though they left the queue" do
      order = order_with(drinks: 1)
      create(:order_item, :finished, order: order, menu_item: menu_item)

      flow = described_class.new(store).load.flows.first

      expect(flow.made_count).to eq(1)
      expect(flow.total_items).to eq(2)
    end

    it "excludes other stores and terminal orders" do
      order_with(drinks: 1, status: "cancelled")
      other = create(:store)
      create(:order_item, order: create(:order, store: other), menu_item: create(:menu_item, store: other))

      expect(described_class.new(store).load.flows).to be_empty
    end

    it "reads the store's scheduler config" do
      store.update!(scheduler_config: { "policy" => "fifo", "quantum" => 300 })

      config = described_class.new(store).load.config

      expect(config.fifo?).to be(true)
      expect(config.quantum).to eq(300)
    end

    # "If Redis is cold, deficits reset to zero, which is safe — it just means
    # one round of unfairness." (§6.5)
    it "starts from zero when Redis has nothing, rather than failing" do
      order_with(drinks: 1)

      expect(described_class.new(store).load.flows.first.deficit).to eq(0)
    end
  end

  describe "round-tripping through Redis (§6.5)" do
    it "restores deficits" do
      order = order_with(drinks: 2)
      state = described_class.new(store).load
      state.flows.first.deficit = 137.5

      described_class.new(store).save(state)

      expect(described_class.new(store).load.flows.first.deficit).to eq(137.5)
      expect(order.reload).to be_present
    end

    # Stored as the order id, never an index — an index means nothing once the
    # flow set is rebuilt from a different queue.
    it "restores the pointer by order id, not by position" do
      first = order_with(drinks: 1, placed_at: 5.minutes.ago)
      second = order_with(drinks: 1, placed_at: 1.minute.ago)

      state = described_class.new(store).load
      state.pointer = 1
      described_class.new(store).save(state)

      # The earlier order finishes, so the flow set shrinks and every index shifts.
      first.order_items.update_all(status: "finished")

      reloaded = described_class.new(store).load
      expect(reloaded.flows.map(&:id)).to eq([ second.id ])
      expect(reloaded.flows[reloaded.pointer].id).to eq(second.id)
    end

    it "falls back to the start when the pointed-at order is gone" do
      gone = order_with(drinks: 1)
      state = described_class.new(store).load
      described_class.new(store).save(state)
      gone.order_items.update_all(status: "finished")
      order_with(drinks: 1)

      expect(described_class.new(store).load.pointer).to eq(0)
    end

    # Without this the flow under the pointer is granted a quantum on every
    # call, can always afford its head, and never yields the ring.
    it "restores which flow has already been granted this round" do
      order = order_with(drinks: 2)
      state = described_class.new(store).load
      Scheduler.pick_next(state, Time.current)

      described_class.new(store).save(state)

      expect(described_class.new(store).load.granted_to).to eq(order.id)
    end

    it "clears the grant once the round moves on" do
      order_with(drinks: 1)
      state = described_class.new(store).load
      described_class.new(store).save(state)

      expect(described_class.new(store).load.granted_to).to be_nil
    end
  end
end
