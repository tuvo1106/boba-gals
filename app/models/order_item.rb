# One drink. This is the unit of work the scheduler operates on (§2), which is
# what reduces "a big order blocks small orders" to fair queuing.
class OrderItem < ApplicationRecord
  # §5.2. queued → in_progress → finished, with failed branching off
  # in_progress and creating a new queued row (remake_of = self).
  STATUSES = %w[queued in_progress finished failed cancelled].freeze

  belongs_to :order
  belongs_to :menu_item
  belongs_to :station, optional: true
  belongs_to :barista, optional: true

  # `finished` is terminal. A failed drink is never un-finished — the remake is
  # a new row pointing back here, which keeps prep-time statistics honest and
  # makes remakes visible in reporting (§5.2).
  belongs_to :remake_of, class_name: "OrderItem", optional: true
  has_many :remakes, class_name: "OrderItem", foreign_key: :remake_of_id, dependent: :nullify,
                     inverse_of: :remake_of

  validates :status, inclusion: { in: STATUSES }
  validates :prep_seconds, numericality: { greater_than: 0 }

  scope :dispatchable, -> { where(status: "queued").order(:queued_at, :id) }
  scope :active, -> { where(status: %w[queued in_progress]) }

  # @return [Boolean] whether this drink exists because an earlier one failed
  def remake?
    remake_of_id.present?
  end
end
