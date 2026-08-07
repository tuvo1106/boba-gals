# A place a drink gets made. Uniform for v1 — station capabilities and item
# requirements (the blender problem) are an open question in §16.
class Station < ApplicationRecord
  belongs_to :store
  has_many :order_items, dependent: :nullify

  validates :name, presence: true

  scope :active, -> { where(active: true) }
end
