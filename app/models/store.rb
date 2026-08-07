# A single boba shop. Everything in the schema is store-scoped, which is what
# keeps multi-store (§16) mostly a routing problem rather than a data-model one.
class Store < ApplicationRecord
  has_many :menu_items, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :stations, dependent: :destroy
  has_many :baristas, dependent: :destroy
  has_many :scheduler_events, dependent: :destroy

  validates :name, presence: true
  validates :timezone, presence: true
  validates :station_count, numericality: { greater_than: 0 }

  # Defaults from §6.6. Merged under the stored config so a key added to the
  # design later doesn't read as nil for stores configured before it existed.
  SCHEDULER_DEFAULTS = {
    "policy" => "drr",
    "quantum" => 120,
    "aging_enabled" => true,
    "aging_rate" => 0.15,
    "cohesion_enabled" => true,
    "cohesion_boost" => 1.0,
    "remake_multiplier" => 4.0,
    "promise_buffer" => 120,
    "quality_limit_seconds" => 300,
    "eta_safety_factor" => 1.15
  }.freeze

  # @return [Hash] the store's scheduler configuration with §6.6 defaults applied
  def effective_scheduler_config
    SCHEDULER_DEFAULTS.merge(scheduler_config || {})
  end

  # Runtime truth for capacity is active stations, not the `station_count`
  # seed column (§4.1).
  # @return [ActiveRecord::Relation<Station>]
  def active_stations
    stations.where(active: true)
  end
end
