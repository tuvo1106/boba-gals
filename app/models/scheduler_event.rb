# Append-only audit trail and the simulator's replay source (§4.1, §10.5).
#
# Never updated, never deleted. Retention is deliberately unbounded — at this
# volume it is megabytes per month, and pruning before replay calibration has
# used the rows would throw away the only record of what actually happened (§15).
class SchedulerEvent < ApplicationRecord
  EVENT_TYPES = %w[
    order_placed item_queued item_started item_finished
    item_remade order_ready order_picked_up quality_breach
  ].freeze

  belongs_to :store
  belongs_to :order_item, optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true

  scope :chronological, -> { order(:occurred_at, :id) }

  # @param store [Store]
  # @param event_type [String] one of EVENT_TYPES
  # @param order_item [OrderItem, nil]
  # @param payload [Hash] must never contain customer_phone (§13.5)
  # @return [SchedulerEvent]
  def self.record!(store:, event_type:, order_item: nil, payload: {}, occurred_at: Time.current)
    create!(store:, event_type:, order_item:, payload:, occurred_at:)
  end
end
