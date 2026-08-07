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

  scope :open, -> { where.not(status: TERMINAL_STATUSES) }

  # @return [Boolean] whether this order is order-ahead rather than ASAP (§6.2)
  def promised?
    promised_at.present?
  end

  # @return [Boolean]
  def terminal?
    TERMINAL_STATUSES.include?(status)
  end
end
