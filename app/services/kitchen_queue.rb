# The KDS view: what is being made, and what is next (§9.2, §9.4).
#
# Payloads are complete snapshots of a bounded view rather than deltas. The
# views are small, and idempotent replacement removes an entire class of sync
# bug — a client that misses a message simply renders the next one correctly.
class KitchenQueue
  # "Always render a Next up section (3 items) so a barista can pre-stage cups
  # and toppings. This is where real throughput comes from." (§9.4)
  NEXT_UP = 3

  # @param store [Store]
  # @return [Hash] the KitchenChannel `queue_update` payload
  def self.call(store)
    in_progress = items_for(store).where(status: "in_progress").order(:started_at).to_a
    queued = items_for(store).where(status: "queued").order(:queued_at, :id)
    next_up = queued.limit(NEXT_UP).to_a
    breached_order_ids = breached_order_ids_among(in_progress + next_up)

    {
      type: "queue_update",
      in_progress: in_progress.map { |i| serialize(i, breached_order_ids) },
      next_up: next_up.map { |i| serialize(i, breached_order_ids) },
      depth: queued.count,
      # Header shows queue depth and the oldest waiting time. Nothing else (§9.4).
      oldest_waiting_seconds: oldest_waiting_seconds(queued)
    }
  end

  # `order: :order_items` and not just `:order`: the card renders the drink's
  # position within its order, which needs the order's other drinks. Without it
  # every serialized card fires its own query for them.
  def self.items_for(store)
    OrderItem.joins(:order).where(orders: { store_id: store.id }).includes(order: :order_items)
  end

  def self.oldest_waiting_seconds(queued)
    oldest = queued.minimum(:queued_at)
    return 0 if oldest.nil?

    (Time.current - oldest).round
  end

  # A breach is logged against a *finished* sibling drink, which has already
  # left this view entirely — a fully-finished order has no KDS row at all
  # (ADR-0005). So the marker rides on whatever's left of the order that's
  # still visible here, warning the barista before the next drink out of the
  # same slow order too (§9.4, §9.6). Scoped to the order ids on screen rather
  # than the store's whole breach history, which only grows (§15).
  #
  # @param items [Array<OrderItem>]
  # @return [Array<Integer>] order ids with at least one logged breach
  def self.breached_order_ids_among(items)
    order_ids = items.map(&:order_id)
    return [] if order_ids.empty?

    SchedulerEvent.joins(:order_item)
                  .where(event_type: "quality_breach", order_items: { order_id: order_ids })
                  .distinct
                  .pluck("order_items.order_id")
  end

  # customer_phone appears nowhere, here or in any other broadcast — the board
  # privacy rule extends to every channel (§13.5).
  def self.serialize(item, breached_order_ids = [])
    countable = item.order.countable_items

    {
      id: item.id,
      label: item.label,
      status: item.status,
      prep_seconds: item.prep_seconds,
      pickup_code: item.order.pickup_code,
      # "2 of 5" — position within its order, so a barista can see the drink is
      # part of a larger order being interleaved (§9.4).
      #
      # Both numbers come from `countable_items`, never from the `sequence`
      # column. A remake is appended with a higher `sequence` than every drink
      # before it (§5.2), so the raw column rendered a spilled two-drink order
      # as "2 of 3" and "3 of 3" — an order that appears to grow because a drink
      # was dropped, while the customer's own screen still said two.
      #
      # `position`, not `sequence`, because that is what it now is. Keeping the
      # old name would invite the next reader to assume it is the column.
      position: countable.index(item) + 1,
      order_size: countable.size,
      remake: item.remake?,
      # A staff-visible marker prompting a check-in or a proactive remake
      # (§9.4, §9.6) — never shown to the customer (§9.5).
      quality_breach: breached_order_ids.include?(item.order_id),
      station_id: item.station_id,
      started_at: item.started_at
    }
  end
end
