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
    in_progress = items_for(store).where(status: "in_progress").order(:started_at)
    queued = items_for(store).where(status: "queued").order(:queued_at, :id)

    {
      type: "queue_update",
      in_progress: in_progress.map { |i| serialize(i) },
      next_up: queued.limit(NEXT_UP).map { |i| serialize(i) },
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

  # customer_phone appears nowhere, here or in any other broadcast — the board
  # privacy rule extends to every channel (§13.5).
  def self.serialize(item)
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
      station_id: item.station_id,
      started_at: item.started_at
    }
  end
end
