# A grouping and payment container — nothing more (§2). The unit of work is
# OrderItem. Order-level scheduling must not creep back in.
class Order < ApplicationRecord
  # §5.1. draft → placed → in_progress → partially_ready → ready → picked_up,
  # with cancelled reachable from the open states and abandoned from ready.
  STATUSES = %w[
    draft placed in_progress partially_ready ready picked_up abandoned cancelled
  ].freeze

  # Terminal, and excluded from the open-orders index and the board.
  TERMINAL_STATUSES = %w[picked_up abandoned cancelled].freeze

  # **The lifecycle stops at `ready` today** (ADR-0017).
  #
  # `RollUpOrderStatus` is the only writer of `status`, and it produces exactly
  # `placed`, `in_progress`, `partially_ready`, `ready`. Nothing reaches the
  # three terminal states: `picked_up` is deliberately unobserved (ADR-0005),
  # `abandoned` needs §5.1's sweep, and there is no cancellation path at all.
  #
  # So `open` currently means "ever placed" and grows by one row per order sold,
  # forever. Do not read it as "still being worked on" — use `live` for that.
  # Measured, this costs nothing: the callers that matter filter on *item*
  # status, which is bounded by real work.
  #
  # How long a customer's own screen keeps receiving pushes after their order is
  # ready. Matches `BoardView::READY_BOARD_TTL` deliberately — the same event
  # seen from two sides of the counter. Generous rather than tight, because
  # `ready` is the last transition there will ever be: once it has been
  # delivered there is nothing further to push.
  LIVE_AFTER_READY = 5.minutes

  SOURCES = %w[kiosk web].freeze

  belongs_to :store
  has_many :order_items, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :pickup_code, presence: true

  # Web orders collect a phone for the single ready SMS (§9.7); kiosk orders
  # never do, because there is nobody to text.
  validates :customer_phone, absence: {
    message: "is only collected for web orders"
  }, if: -> { source == "kiosk" }

  # Optional, but if it is given it has to be able to receive a text.
  #
  # 10 to 15 digits: E.164 caps a number at 15 digits including the country
  # code, and nothing shorter than 10 is a mobile number anyone can be reached
  # on. Formatting the customer typed — spaces, dashes, brackets, dots — is
  # stripped before counting rather than rejected, because "(555) 555-0123" is a
  # phone number and refusing it teaches people to distrust the field.
  #
  # **No country code is inferred.** A bare 10-digit number is stored as typed,
  # not silently turned into `+1…`: this shop has no country on record, and
  # guessing wrong sends the ready text to a stranger. Twilio needs E.164, so
  # normalisation has to happen when that integration lands and knows where the
  # store is — see §16.
  PHONE_FORMAT = /\A\+?\d{10,15}\z/
  PHONE_PUNCTUATION = /[\s().\-]/

  validates :customer_phone, format: {
    with: PHONE_FORMAT,
    message: "is not a phone number that can receive a text"
  }, allow_blank: true

  # Runs before validation so the format above sees digits, and so what is
  # stored is what would be dialled.
  before_validation :squeeze_phone

  scope :open, -> { where.not(status: TERMINAL_STATUSES) }

  # Orders a customer could still be watching (§9.2).
  #
  # Bounded in SQL rather than by a background job marking orders closed. The
  # job version needs a terminal state nothing can honestly set — stamping
  # `abandoned` on drinks people happily collected — and it leaves the set
  # unbounded again whenever the worker is behind, which #40 shows it is.
  # `BoardView` already settled this shape for the board (ADR-0005): the view
  # clears itself on a timer, in the query.
  scope :live, ->(now = Time.current) {
    where(status: %w[placed in_progress partially_ready])
      .or(where(status: "ready").where(ready_at: (now - LIVE_AFTER_READY)..))
  }

  # The pickup code *is* the capability token (§13.1), and it is unique per
  # store per *day* — so a lookup that ignores the date hands yesterday's code
  # a read of today's order.
  #
  # Both doors go through here: `GET /orders/:pickup_code` (§9.1) and
  # `OrderChannel` (§9.2). A channel that scoped this differently from the REST
  # endpoint would be a second, weaker lock on the same room.
  scope :for_pickup_code, ->(code, on: Date.current) {
    where(pickup_code: code.to_s.upcase).where("placed_at::date = ?", on)
  }

  # @return [Boolean] whether this order is order-ahead rather than ASAP (§6.2)
  def promised?
    promised_at.present?
  end

  # @return [Boolean]
  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # The drinks this order is actually for, in order (§5.2).
  #
  # A failed drink has already produced a remake row that stands in its place,
  # and a cancelled one was never going to be made — so neither is a drink the
  # customer is waiting for or the shop still owes. Counting them makes a
  # two-drink order look like a three-drink order the moment anything goes
  # wrong, on every surface that counts drinks.
  #
  # This is deliberately one method rather than the same `select` written in
  # each view. It was written twice before, and the second copy was missed:
  # `OrderView` excluded failed rows while the KDS did not, so a barista and
  # their customer read different numbers off the same order.
  #
  # Sorted by `sequence` — the column is the scheduler's ordering key and stays
  # gap-free-agnostic, so position in this list is what a surface should render,
  # never the raw column (§9.4).
  #
  # @return [Array<OrderItem>]
  def countable_items
    order_items
      .select { |item| RollUpOrderStatus::COUNTED_STATUSES.include?(item.status) }
      .sort_by(&:sequence)
  end

  private

  def squeeze_phone
    return if customer_phone.blank?

    self.customer_phone = customer_phone.strip.gsub(PHONE_PUNCTUATION, "")
  end
end
