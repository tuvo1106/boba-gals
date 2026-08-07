require "rails_helper"

RSpec.describe CreateOrder do
  let(:store) { create(:store, :with_stations) }
  let(:service) { described_class.new(store: store) }

  def place(items:, **overrides)
    service.call(source: "kiosk", items: items, **overrides)
  end

  describe "prep_seconds" do
    # The whole design rests on drinks being genuinely different units of work
    # (§2). If prep_seconds were uniform, fair queuing would have nothing to do.
    it "freezes base prep time plus the sum of option deltas" do
      item = create(:menu_item, :brown_sugar_pearl, store: store)
      group = create(:option_group, menu_item: item, name: "Toppings", min_select: 0, max_select: 2)
      pearls = create(:option, option_group: group, name: "Extra pearls", prep_seconds_delta: 15)
      jelly  = create(:option, option_group: group, name: "Grass jelly", prep_seconds_delta: 10)

      result = place(items: [ { menu_item_id: item.id, option_ids: [ pearls.id, jelly.id ] } ])

      expect(result).to be_success
      expect(result.order.order_items.sole.prep_seconds).to eq(95 + 15 + 10)
    end

    it "does not change when the menu item is edited afterwards" do
      item = create(:menu_item, store: store, base_prep_seconds: 40)
      result = place(items: [ { menu_item_id: item.id } ])

      item.update!(base_prep_seconds: 300)

      expect(result.order.order_items.sole.reload.prep_seconds).to eq(40),
        "prep_seconds is a snapshot — editing the menu must not rewrite history (§4.1)"
    end
  end

  describe "queueing" do
    # Each drink is independently queueable — that is what reduces "big order
    # blocks small order" to a solved problem (§2).
    it "queues every drink as its own unit of work" do
      item = create(:menu_item, store: store)

      result = place(items: Array.new(3) { { menu_item_id: item.id } })

      expect(result.order.order_items.count).to eq(3)
      expect(result.order.order_items.pluck(:status)).to all(eq("queued"))
      expect(result.order.order_items.pluck(:sequence)).to contain_exactly(1, 2, 3)
    end

    it "stamps queued_at so FIFO has something to order by" do
      item = create(:menu_item, store: store)

      result = place(items: [ { menu_item_id: item.id } ])

      expect(result.order.order_items.sole.queued_at).to be_present
    end
  end

  describe "quoted_wait_seconds" do
    # The estimate must include the drinks the customer just ordered. Quoting
    # before they are queued tells the first customer of the day they will wait
    # zero seconds — and an ETA people learn to distrust is worse than none
    # (§7.3). Replaced by the §7.1 forward projection at build step 7.
    it "accounts for the order's own work, not just the queue ahead of it" do
      item = create(:menu_item, :brown_sugar_pearl, store: store)

      result = place(items: [ { menu_item_id: item.id } ])

      expect(result.order.quoted_wait_seconds).to be_positive
    end

    it "grows as the queue deepens" do
      item = create(:menu_item, :brown_sugar_pearl, store: store)

      first = place(items: [ { menu_item_id: item.id } ])
      second = place(items: [ { menu_item_id: item.id } ])

      expect(second.order.quoted_wait_seconds).to be > first.order.quoted_wait_seconds
    end
  end

  describe "denormalized snapshots" do
    it "builds a display label from the drink and its options" do
      item = create(:menu_item, store: store, name: "Brown Sugar Pearl")
      group = create(:option_group, menu_item: item, min_select: 0, max_select: 2)
      half = create(:option, option_group: group, name: "50%")
      less = create(:option, option_group: group, name: "less ice")

      result = place(items: [ { menu_item_id: item.id, option_ids: [ half.id, less.id ] } ])

      expect(result.order.order_items.sole.label).to eq("Brown Sugar Pearl, 50%, less ice")
    end

    it "snapshots the chosen options with their deltas" do
      item = create(:menu_item, store: store)
      group = create(:option_group, menu_item: item, min_select: 0, max_select: 1)
      option = create(:option, option_group: group, name: "Boba pearls", prep_seconds_delta: 15)

      result = place(items: [ { menu_item_id: item.id, option_ids: [ option.id ] } ])

      expect(result.order.order_items.sole.selected_options).to eq(
        [ { "option_id" => option.id, "name" => "Boba pearls", "prep_seconds_delta" => 15 } ]
      )
    end
  end

  describe "pricing" do
    it "totals drink prices plus option prices" do
      item = create(:menu_item, store: store, price_cents: 550)
      group = create(:option_group, menu_item: item, min_select: 0, max_select: 1)
      option = create(:option, option_group: group, price_cents: 75)

      result = place(items: [
        { menu_item_id: item.id, option_ids: [ option.id ] },
        { menu_item_id: item.id
        }
      ])

      expect(result.order.total_cents).to eq(550 + 75 + 550)
    end
  end

  describe "validation" do
    it "refuses orders when the store is not accepting them" do
      closed = create(:store, :closed)
      item = create(:menu_item, store: closed)

      result = described_class.new(store: closed).call(source: "kiosk", items: [ { menu_item_id: item.id } ])

      expect(result).not_to be_success
      expect(result.errors).to include(/not accepting orders/)
    end

    it "refuses an empty order" do
      expect(place(items: [])).not_to be_success
    end

    it "refuses an unavailable drink" do
      item = create(:menu_item, :unavailable, store: store)

      result = place(items: [ { menu_item_id: item.id } ])

      expect(result).not_to be_success
      expect(result.errors.first).to match(/unknown or unavailable/)
    end

    it "refuses options belonging to a different drink" do
      item = create(:menu_item, store: store)
      other = create(:menu_item, :with_options, store: store)
      foreign_option = other.option_groups.first.options.first

      result = place(items: [ { menu_item_id: item.id, option_ids: [ foreign_option.id ] } ])

      expect(result).not_to be_success
      expect(result.errors.first).to match(/do not belong to/)
    end

    it "enforces min_select on a required group" do
      item = create(:menu_item, store: store)
      create(:option_group, menu_item: item, name: "Sweetness", min_select: 1, max_select: 1)

      result = place(items: [ { menu_item_id: item.id } ])

      expect(result).not_to be_success
      expect(result.errors.first).to match(/Sweetness requires at least 1/)
    end

    it "enforces max_select on a multi-select group" do
      item = create(:menu_item, store: store)
      group = create(:option_group, menu_item: item, name: "Toppings", min_select: 0, max_select: 1)
      a = create(:option, option_group: group)
      b = create(:option, option_group: group)

      result = place(items: [ { menu_item_id: item.id, option_ids: [ a.id, b.id ] } ])

      expect(result).not_to be_success
      expect(result.errors.first).to match(/Toppings allows at most 1/)
    end

    it "writes nothing when any drink in the order is invalid" do
      good = create(:menu_item, store: store)

      expect {
        place(items: [ { menu_item_id: good.id }, { menu_item_id: -1 } ])
      }.not_to change(Order, :count)
    end
  end

  describe "customer_phone (§13.5)" do
    it "is recorded for web orders" do
      item = create(:menu_item, store: store)

      result = service.call(source: "web", items: [ { menu_item_id: item.id } ],
                            customer_phone: "+15555550123")

      expect(result.order.customer_phone).to eq("+15555550123")
    end

    it "is discarded for kiosk orders, which have nobody to text" do
      item = create(:menu_item, store: store)

      result = place(items: [ { menu_item_id: item.id } ], customer_phone: "+15555550123")

      expect(result.order.customer_phone).to be_nil
    end
  end

  describe "audit trail" do
    it "records an order_placed event (§4.1)" do
      item = create(:menu_item, store: store)

      expect { place(items: [ { menu_item_id: item.id } ]) }
        .to change { SchedulerEvent.where(event_type: "order_placed").count }.by(1)
    end
  end

  describe "payment (§9.3)" do
    it "settles through the counter provider by default" do
      item = create(:menu_item, store: store)

      expect(place(items: [ { menu_item_id: item.id } ])).to be_success
    end

    it "rolls the order back if a provider declines" do
      item = create(:menu_item, store: store)
      declining = Class.new do
        def authorize(_order)
          PaymentProvider::Result.new(success?: false, error: "card declined")
        end
      end.new

      result = described_class.new(store: store, payment_provider: declining)
                              .call(source: "kiosk", items: [ { menu_item_id: item.id } ])

      expect(result).not_to be_success
      expect(Order.count).to eq(0)
    end
  end
end
