# Places an order: validates the requested drinks against the menu, freezes
# their prep times and labels, and queues each drink as an independent unit of
# work (§2).
#
# Build step 1 is FIFO only — items are queued with `queued_at` and the KDS
# takes them in that order. The scheduler (§6) arrives at step 5 and changes
# only which queued item gets picked, never how they got here.
class CreateOrder
  Result = Struct.new(:success?, :order, :errors, keyword_init: true)

  class InvalidRequest < StandardError; end

  # @param store [Store]
  # @param payment_provider [#authorize] defaults to the §9.3 counter provider
  def initialize(store:, payment_provider: PaymentProvider.current)
    @store = store
    @payment_provider = payment_provider
  end

  # @param source [String] "kiosk" or "web"
  # @param items [Array<Hash>] `[{ menu_item_id:, option_ids: [] }, ...]`
  # @param customer_first_name [String, nil] shown on the board (§9.5)
  # @param customer_phone [String, nil] web only; never displayed or logged (§13.5)
  # @param promised_at [Time, nil] order-ahead target; nil means ASAP
  # @return [CreateOrder::Result]
  def call(source:, items:, customer_first_name: nil, customer_phone: nil, promised_at: nil)
    return failure([ "store is not accepting orders" ]) unless @store.accepting_orders?
    return failure([ "order must contain at least one drink" ]) if items.blank?

    built = build_items(items)

    order = nil
    Order.transaction do
      order = create_order(source:, customer_first_name:, customer_phone:, promised_at:, built:)
      persist_items(order, built)

      # Quoted only after this order's drinks are queued, so the estimate
      # includes the work the customer just created. Quoting before they exist
      # tells the first customer of the day they will wait zero seconds, which
      # is the fastest way to teach people the number is a lie (§7.3).
      #
      # The projection reads Redis for the live deficits (§6.5). That is a read,
      # not a side effect, so it is safe inside the transaction in a way §8's
      # ban on broadcasts and jobs is not about — nothing here needs rolling
      # back if the payment below is declined.
      order.update!(quoted_wait_seconds: ProjectEta.for_order(@store, order))

      payment = @payment_provider.authorize(order)
      raise InvalidRequest, payment.error || "payment was declined" unless payment.success?

      SchedulerEvent.record!(
        store: @store,
        event_type: "order_placed",
        payload: { order_id: order.id, item_count: built.size, source: source }
      )
    end

    # Deliberately outside the transaction: broadcasts and jobs never run inside
    # one (§8). A placed order has to reach the kitchen and the board without
    # anyone refreshing anything — it is the only transition a customer watches
    # for directly.
    BroadcastStoreViews.call(@store)

    Result.new(success?: true, order: order.reload, errors: [])
  rescue InvalidRequest => e
    failure([ e.message ])
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record.errors.full_messages)
  end

  private

  def create_order(source:, customer_first_name:, customer_phone:, promised_at:, built:)
    placed_at = Time.current

    @store.orders.create!(
      source: source,
      status: "placed",
      placed_at: placed_at,
      promised_at: promised_at,
      pickup_code: PickupCode.generate_unique(store: @store, on: placed_at.to_date),
      customer_first_name: customer_first_name.presence,
      customer_phone: (customer_phone.presence if source == "web"),
      total_cents: built.sum { |b| b[:price_cents] }
    )
  end

  def persist_items(order, built)
    queued_at = Time.current

    built.each_with_index do |b, index|
      order.order_items.create!(
        menu_item: b[:menu_item],
        selected_options: b[:selected_options],
        label: b[:label],
        prep_seconds: b[:prep_seconds],
        status: "queued",
        queued_at: queued_at,
        sequence: index + 1
      )
    end
  end

  # Resolves each requested drink against the menu and freezes what it costs and
  # how long it takes. Both are snapshots: editing the menu later must not
  # rewrite what a customer actually ordered (§4.1).
  def build_items(items)
    items.map do |raw|
      menu_item = @store.menu_items.available.find_by(id: raw[:menu_item_id])
      raise InvalidRequest, "unknown or unavailable menu item #{raw[:menu_item_id]}" if menu_item.nil?

      options = resolve_options(menu_item, Array(raw[:option_ids]))
      validate_selection_counts!(menu_item, options)

      {
        menu_item: menu_item,
        selected_options: options.map do |o|
          { "option_id" => o.id, "name" => o.name, "prep_seconds_delta" => o.prep_seconds_delta }
        end,
        label: label_for(menu_item, options),
        prep_seconds: menu_item.base_prep_seconds + options.sum(&:prep_seconds_delta),
        price_cents: menu_item.price_cents + options.sum(&:price_cents)
      }
    end
  end

  def resolve_options(menu_item, option_ids)
    return [] if option_ids.empty?

    options = Option.where(id: option_ids, option_group: menu_item.option_groups).to_a

    missing = option_ids.map(&:to_i) - options.map(&:id)
    raise InvalidRequest, "options #{missing.join(', ')} do not belong to #{menu_item.name}" if missing.any?

    options
  end

  def validate_selection_counts!(menu_item, options)
    by_group = options.group_by(&:option_group_id)

    menu_item.option_groups.each do |group|
      count = by_group.fetch(group.id, []).size

      if count < group.min_select.to_i
        raise InvalidRequest, "#{group.name} requires at least #{group.min_select} selection(s)"
      end

      if count > group.max_select.to_i
        raise InvalidRequest, "#{group.name} allows at most #{group.max_select} selection(s)"
      end
    end
  end

  # The denormalized display string the KDS and board render, e.g.
  # "Brown Sugar Pearl, 50%, less ice" (§4.1, §9.4).
  def label_for(menu_item, options)
    return menu_item.name if options.empty?

    "#{menu_item.name}, #{options.map(&:name).join(', ')}"
  end

  def failure(messages)
    Result.new(success?: false, order: nil, errors: messages)
  end
end
