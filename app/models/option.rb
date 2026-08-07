# 50% sugar, Extra pearls, Large.
#
# `prep_seconds_delta` is why the scheduler can treat drinks as genuinely
# different units of work: extra pearls really does add ~15s (§4.1).
class Option < ApplicationRecord
  belongs_to :option_group

  validates :name, presence: true
  validates :price_cents, numericality: true
  validates :prep_seconds_delta, numericality: true
end
