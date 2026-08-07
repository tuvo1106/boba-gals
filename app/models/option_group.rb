# Sweetness, Ice, Toppings, Size. `min_select`/`max_select` drive the ordering
# UI's control choice — RadioGroup when max is 1, Checkbox otherwise (ADR-0003).
class OptionGroup < ApplicationRecord
  belongs_to :menu_item
  has_many :options, dependent: :destroy

  validates :name, presence: true
  validates :min_select, numericality: { greater_than_or_equal_to: 0 }
  validates :max_select, numericality: { greater_than_or_equal_to: 1 }
  validate :max_select_not_below_min_select

  # @return [Boolean] whether the customer must choose from this group
  def required?
    min_select.to_i.positive?
  end

  private

  def max_select_not_below_min_select
    return if min_select.blank? || max_select.blank?
    return if max_select >= min_select

    errors.add(:max_select, "must be greater than or equal to min_select")
  end
end
