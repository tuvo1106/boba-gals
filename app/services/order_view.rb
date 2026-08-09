# One customer's view of their own order (§9.2).
#
# The narrowest view in the system, and deliberately so. It is reached with a
# `pickup_code` and nothing else (§13.1), so it carries only what the person
# holding that code already knows — never `customer_phone` (§13.5), and never
# anything about anyone else's order.
#
# Per-item status is what makes a multi-drink order legible while it is being
# made: §6 interleaves the drinks of one order with everyone else's, so a
# customer watching a five-drink order sees three done and two still going
# rather than a single bar that sits at "in progress" for eight minutes.
class OrderView
  # @param order [Order]
  # @param eta_seconds [Integer] from `EtaCache`, not recomputed here
  # @return [Hash] the OrderChannel `order_update` payload
  def self.call(order, eta_seconds: 0)
    {
      type: "order_update",
      # Additive to the §9.2 sketch. The stream is per code already, but a
      # client that reconnects while the page is being reused for a second
      # order has no other way to tell whose frame it just received.
      pickup_code: order.pickup_code,
      status: order.status,
      eta_seconds: eta_seconds,
      # Failed and cancelled drinks are omitted, not shown as "remaking".
      #
      # A remade drink already has a replacement row (§5.2), so leaving the
      # failed one in shows a customer three rows for a two-drink order and
      # explains neither. What they ordered is two drinks; what they should see
      # is two lines. `Order#countable_items` is the same rule the order's own
      # status is derived from, so the list and the headline cannot disagree —
      # and it is shared with the KDS, which used to disagree with both.
      items: order.countable_items.map do |item|
        { id: item.id, label: item.label, status: item.status }
      end
    }
  end
end
