require "rails_helper"

RSpec.describe SendReadySmsJob do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  # A seeded demo number. Never a real one — PR bodies and Actions logs are
  # public (CLAUDE.md), and this is the field §13.5 exists for.
  let(:phone) { "+15555550123" }

  def ready_web_order(**attrs)
    order = create(:order, :web, store: store, status: "ready", ready_at: Time.current,
                                 customer_phone: phone, **attrs)
    create(:order_item, :finished, order: order, menu_item: menu_item, sequence: 1)
    order
  end

  # One double for the port, stubbed to succeed by default. Examples that care
  # about failure override it.
  let(:sender) { instance_double(LogSender) }

  before do
    allow(NotificationSender).to receive(:current).and_return(sender)
    allow(sender).to receive(:deliver).and_return(NotificationSender::Result.new(success?: true))
  end

  describe "who gets a message (§9.7)" do
    it "texts a web customer when their order is ready" do
      order = ready_web_order

      described_class.perform_now(order.id)

      # §9.7's wording, verbatim.
      expect(sender).to have_received(:deliver)
        .with(to: phone, body: "Your Boba Gals order #{order.pickup_code} is ready for pickup!")
    end

    # §9.7 is web-only "because there is nobody to text" — and `Order` rejects a
    # `customer_phone` on a kiosk order outright, so there is no number anyway.
    it "does not text a kiosk order" do
      order = create(:order, store: store, source: "kiosk", status: "ready", ready_at: Time.current)
      create(:order_item, :finished, order: order, menu_item: menu_item, sequence: 1)

      described_class.perform_now(order.id)

      expect(sender).not_to have_received(:deliver)
    end

    it "does not text a web order placed without a phone" do
      order = ready_web_order(customer_phone: nil)

      described_class.perform_now(order.id)

      expect(sender).not_to have_received(:deliver)
    end

    # An undo (§5.2) between the enqueue and the run moves the order back out of
    # ready. Texting then would send someone to the counter for a drink still
    # being made.
    it "does not text an order that is no longer ready" do
      order = ready_web_order(status: "in_progress", ready_at: nil)

      described_class.perform_now(order.id)

      expect(sender).not_to have_received(:deliver)
    end

    it "does nothing for an order that has gone away" do
      expect { described_class.perform_now(-1) }.not_to raise_error
    end
  end

  # §9.7: "Exactly one message." `ready` is reachable more than once — the KDS
  # undo moves an order back out of it and a re-finish re-enters it — so the
  # guard is a column that is set once and never cleared.
  describe "exactly one, however many times ready is reached" do
    it "claims the send so a second run does nothing" do
      order = ready_web_order

      described_class.perform_now(order.id)
      described_class.perform_now(order.id)

      expect(sender).to have_received(:deliver).once
    end

    it "records when the message was claimed" do
      order = ready_web_order

      expect { described_class.perform_now(order.id) }
        .to change { order.reload.ready_sms_sent_at }.from(nil)
    end

    it "does nothing when the message was already claimed" do
      order = ready_web_order
      order.update_columns(ready_sms_sent_at: Time.current)

      described_class.perform_now(order.id)

      expect(sender).not_to have_received(:deliver)
    end
  end

  # "No retry beyond Sidekiq's default; a lost SMS is a shrug, not an incident.
  # Never block or fail an order transition on SMS failure." (§9.7)
  describe "when the sender fails" do
    it "does not raise" do
      order = ready_web_order
      allow(sender).to receive(:deliver)
        .and_return(NotificationSender::Result.new(success?: false, error: "boom"))

      expect { described_class.perform_now(order.id) }.not_to raise_error
    end

    # Un-claiming would re-send on the next transition, trading "no message"
    # for "two messages" — the worse of the two.
    it "stays claimed, so a later transition does not send a second time" do
      order = ready_web_order
      allow(sender).to receive(:deliver)
        .and_return(NotificationSender::Result.new(success?: false, error: "boom"))

      described_class.perform_now(order.id)

      expect(order.reload.ready_sms_sent_at).to be_present
    end
  end
end
