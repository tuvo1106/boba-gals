# The single "your order is ready" text (§9.7).
#
# **Never blocks or fails an order transition.** It is enqueued after the
# transition has already committed, and anything that goes wrong in here stays
# in here — a lost SMS is a shrug, not an incident (§9.7).
#
# No retry configuration beyond Sidekiq's default, deliberately. §9.7 says so,
# and a message about a drink that was ready twenty minutes ago is worse than no
# message.
class SendReadySmsJob < ApplicationJob
  queue_as :default

  # @param order_id [Integer]
  # @return [void]
  def perform(order_id)
    order = Order.find_by(id: order_id)
    return if order.nil?

    # Re-checked here, not only at the call site. The guard has to hold against
    # two web pods finishing the last two drinks of one order at the same
    # instant (§14.2) — `update_all` with the `nil` check in the WHERE clause is
    # what makes the claim atomic, so exactly one caller wins.
    return unless eligible?(order)
    return if claim(order).zero?

    result = NotificationSender.current.deliver(
      to: order.customer_phone,
      body: NotificationSender.ready_message(order)
    )

    return if result.success?

    # Logged and dropped. Un-claiming would re-send on the next transition,
    # which trades "no message" for "two messages" — the worse of the two.
    Rails.logger.warn("[sms] delivery failed for order #{order.pickup_code}: #{result.error}")
  end

  private

  # A phone and still ready.
  #
  # No `source == "web"` check, deliberately. §9.7 is web-only "because there is
  # nobody to text" — and `Order` enforces exactly that, rejecting a
  # `customer_phone` when `source == "kiosk"`. So a kiosk order has no number
  # and is already excluded here; adding the check back would be a branch no
  # test could reach, which is how a guard ends up believed rather than known.
  #
  # `status == "ready"` is re-read because an undo (§5.2) between the enqueue
  # and the run moves the order back out of ready, and texting then sends
  # someone to the counter for a drink still being made.
  def eligible?(order)
    order.customer_phone.present? && order.status == "ready"
  end

  # A conditional UPDATE, not a read-then-write: two `web` pods can finish the
  # last two drinks of one order in the same instant (§14.2), and only the
  # `WHERE ready_sms_sent_at IS NULL` makes exactly one of them win.
  #
  # **Not covered by a test, deliberately.** An attempt at a threaded example
  # could not distinguish this from a check-then-write — both reported one send
  # — so it was removed rather than left implying coverage it did not have. The
  # single-threaded examples cover the guard; the concurrent case rests on the
  # database, which is the right place for it to rest.
  #
  # @return [Integer] rows claimed: 1 for the winner, 0 for everyone else
  def claim(order)
    Order.where(id: order.id, ready_sms_sent_at: nil).update_all(ready_sms_sent_at: Time.current)
  end
end
