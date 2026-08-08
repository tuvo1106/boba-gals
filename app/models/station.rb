# A place a drink gets made. Uniform for v1 — station capabilities and item
# requirements (the blender problem) are an open question in §16.
class Station < ApplicationRecord
  belongs_to :store
  has_many :order_items, dependent: :nullify

  validates :name, presence: true

  scope :active, -> { where(active: true) }

  # §7.2 lists "station activated or deactivated" as an ETA recompute trigger,
  # and it is the one with the largest effect: capacity is the divisor in every
  # projection, so opening a fourth bar changes every number on the board at
  # once.
  #
  # On the model rather than a controller because there is no station endpoint
  # yet (§16 leaves station capabilities open) — today this is toggled from the
  # console and from seeds, and a trigger that only fires over HTTP would miss
  # both. `after_commit`, never inside the transaction (§8).
  after_commit :recompute_store_eta, if: :saved_change_to_active?

  private

  def recompute_store_eta
    RecomputeEta.call(store)
  end
end
