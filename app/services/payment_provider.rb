# The payment port (§9.3).
#
# v1 is locked to pay-at-counter: record `total_cents`, settle at the register.
# Terminal and Stripe integrations are integration work, not design work, and
# sit behind this port so they can arrive after the scheduler is proven.
#
# Authorized when the order is placed, not at collection (§9.3, #55) —
# `CreateOrder` calls `#authorize` inside the same transaction that creates the
# order and queues its items, so a declined payment rolls both back.
module PaymentProvider
  Result = Struct.new(:success?, :reference, :error, keyword_init: true)

  # @param order [Order]
  # @return [PaymentProvider::Result]
  def authorize(order)
    raise NotImplementedError, "#{self.class} must implement #authorize"
  end

  # @return [#authorize] the provider for the current environment
  def self.current
    CounterPayment.new
  end
end
