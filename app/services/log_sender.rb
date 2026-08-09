# The development, test and simulation notification sender (§9.7).
#
# Writes a line saying a message would have been sent. Nobody is texted.
#
# **It never logs the number.** §13.5: `customer_phone` never appears in logs.
# A log-writing sender is the single most likely place in the application to
# break that rule, because logging its own arguments is the obvious thing for it
# to do — so it logs the pickup code, which identifies the order without
# identifying the person, and a digit count so an operator can still tell a
# missing number from a malformed one.
class LogSender
  include NotificationSender

  # @param to [String] E.164 phone number — used to confirm a number exists, never logged
  # @param body [String] the message
  # @return [NotificationSender::Result]
  def deliver(to:, body:)
    Rails.logger.info(
      "[sms] would send to a #{to.to_s.gsub(/\D/, '').length}-digit number: #{body}"
    )

    Result.new(success?: true, reference: "log")
  end
end
