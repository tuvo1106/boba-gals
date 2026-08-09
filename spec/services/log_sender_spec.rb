require "rails_helper"

RSpec.describe LogSender do
  # A seeded demo number, never a real one (CLAUDE.md, §13.5).
  let(:phone) { "+15555550123" }

  def logged(&block)
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    block.call
    io.string
  ensure
    Rails.logger = original
  end

  it "reports what would have been sent" do
    output = logged { described_class.new.deliver(to: phone, body: "order R55Z is ready") }

    expect(output).to include("order R55Z is ready")
  end

  it "succeeds, because nothing can go wrong writing a log line" do
    expect(described_class.new.deliver(to: phone, body: "x")).to be_success
  end

  # §13.5: `customer_phone` never appears in logs. A log-writing sender is the
  # single most likely place in the application to break that rule, because
  # logging its own arguments is the obvious thing for it to do.
  #
  # This is the guard, and it is deliberately literal about the digits rather
  # than matching a format — a sender that logged `to` with the `+` stripped, or
  # dash-separated, would still have leaked the number.
  it "never writes the phone number" do
    output = logged { described_class.new.deliver(to: phone, body: "order R55Z is ready") }

    expect(output).not_to include(phone)
    expect(output).not_to include("5555550123")
    expect(output).not_to include("555-555-0123")
  end

  # An operator still needs to tell a missing number from a malformed one, which
  # a bare "sent a message" line cannot do.
  it "says how many digits it had, so a bad number is still diagnosable" do
    output = logged { described_class.new.deliver(to: phone, body: "x") }

    expect(output).to include("11-digit")
  end

  it "does not blow up on a missing number" do
    expect { logged { described_class.new.deliver(to: nil, body: "x") } }.not_to raise_error
  end
end
