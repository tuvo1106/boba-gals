# The payment port (§9.3).
#
# v1 is locked to pay-at-counter: record `total_cents`, settle at the register.
# Terminal and Stripe integrations are integration work, not design work, and
# sit behind this port so they can arrive after the scheduler is proven.
#
# Nothing in the scheduler depends on payment state, which is also what defers
# the payment-failure open question in §16.
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
