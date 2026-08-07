# A drink on the menu. `base_prep_seconds` is the seeded estimate; observed
# durations refine it via the EWMA in prep_time_stats from build step 7 (§7.3).
class MenuItem < ApplicationRecord
  CATEGORIES = %w[milk_tea fruit_tea slush specialty].freeze

  belongs_to :store
  has_many :option_groups, dependent: :destroy
  has_many :order_items, dependent: :restrict_with_error
  has_one :prep_time_stat, dependent: :destroy

  validates :name, presence: true
  validates :base_prep_seconds, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  scope :available, -> { where(available: true) }
  scope :ordered, -> { order(Arel.sql("position NULLS LAST"), :name) }
end
