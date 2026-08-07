# Order responses for the public endpoints (§9.1).
#
# `customer_phone` is absent by construction, not by omission — §13.5 excludes
# it from every serializer except the admin order view, and the board privacy
# rule (§3) extends the same restriction to every ActionCable payload.
# spec/serializers/order_serializer_spec.rb holds this line.
module OrderSerializer
  # @param order [Order]
  # @return [Hash]
  def self.call(order)
    {
      pickup_code: order.pickup_code,
      status: order.status,
      source: order.source,
      customer_first_name: order.customer_first_name,
      placed_at: order.placed_at,
      promised_at: order.promised_at,
      ready_at: order.ready_at,
      total_cents: order.total_cents,
      quoted_wait_seconds: order.quoted_wait_seconds,
      items: order.order_items.order(:sequence).map { |item| serialize_item(item) }
    }
  end

  def self.serialize_item(item)
    {
      id: item.id,
      label: item.label,
      status: item.status,
      prep_seconds: item.prep_seconds,
      sequence: item.sequence,
      remake: item.remake?
    }
  end
end
