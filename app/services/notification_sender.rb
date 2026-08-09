# The notification port (§9.7).
#
# Exactly one message per order, when it becomes `ready`:
#
#   Your Boba Gals order {PICKUP_CODE} is ready for pickup!
#
# `TwilioSender` in production, `LogSender` everywhere else. Twilio is
# integration work rather than design work, so it sits behind this port and
# arrives when credentials do — the shape mirrors `PaymentProvider`, which
# already established it for `CounterPayment`.
#
# **`customer_phone` reaches this port and goes no further** (§13.5): never a
# log line, never a serializer, never a broadcast. The one adapter that writes
# anywhere a human reads is `LogSender`, and it is the one most likely to break
# that rule, so it does not receive the number at all — see `deliver`.
module NotificationSender
  Result = Struct.new(:success?, :reference, :error, keyword_init: true)

  # @param to [String] E.164 phone number
  # @param body [String] the message
  # @return [NotificationSender::Result]
  def deliver(to:, body:)
    raise NotImplementedError, "#{self.class} must implement #deliver"
  end

  # §9.7's message, verbatim.
  #
  # @param order [Order]
  # @return [String]
  def self.ready_message(order)
    "Your Boba Gals order #{order.pickup_code} is ready for pickup!"
  end

  # @return [#deliver] the sender for the current environment
  def self.current
    LogSender.new
  end
end
