# EWMA of observed prep durations per menu item (§7.3).
#
# Unused until build step 7. It exists in the schema from the start because the
# difference between a board customers trust and one they learn to ignore is
# whether these numbers are real rather than seeded guesses.
class PrepTimeStat < ApplicationRecord
  ALPHA = 0.2

  # Below this, the seeded base_prep_seconds still wins (§7.3).
  MINIMUM_SAMPLES = 10

  belongs_to :menu_item

  validates :menu_item_id, uniqueness: true
  validates :sample_count, numericality: { greater_than_or_equal_to: 0 }

  # @return [Boolean] whether the learned value should override the seed
  def confident?
    sample_count >= MINIMUM_SAMPLES && ewma_seconds.present?
  end
end
