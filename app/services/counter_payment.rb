# Pay-at-counter: the v1 payment implementation, locked for solo scope (§9.3).
#
# Always succeeds. The customer pays a human at the register, so there is no
# authorization to fail — the order simply records what is owed.
class CounterPayment
  include PaymentProvider

  # @param order [Order]
  # @return [PaymentProvider::Result]
  def authorize(order)
    PaymentProvider::Result.new(success?: true, reference: "counter:#{order.pickup_code}")
  end
end
