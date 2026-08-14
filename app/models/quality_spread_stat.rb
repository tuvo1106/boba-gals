# EWMA of an order's spread — ready_at - first_ready_at — per size class (§9.6,
# #80). ADR-0014 showed the flat quality_limit_seconds is blunt: a 3+ drink
# order's typical spread already blows past 300s several times over, so the
# breach marker was firing on nearly every multi-drink order rather than on
# unusually slow ones. This scores each size class against its own learned
# baseline instead.
#
# Scoped per store, unlike PrepTimeStat's per-menu-item scope (ADR-0031):
# prep time is a fixed physical property of a drink, but spread depends on a
# store's own staffing and demand, which two stores selling the same drinks
# do not share.
class QualitySpreadStat < ApplicationRecord
  ALPHA = 0.2

  # Below this, the seeded multiplier over quality_limit_seconds still wins.
  MINIMUM_SAMPLES = 10

  # ~90th percentile under a normal approximation (z ≈ 1.28) — "unusually slow
  # for this size", not an arbitrary multiplier over the mean.
  THRESHOLD_Z = 1.28

  # Multiplier over the store's own quality_limit_seconds, used until this
  # size class has a confident learned threshold (#80). Derived from
  # ADR-0014's measured p90 spread (~120s / ~1500s / ~5000s for 1-2 / 3-6 /
  # 7+) at roughly 1.2x headroom over the observed p90, expressed relative to
  # the 300s default so a store that has already tuned quality_limit_seconds
  # gets a proportionally scaled answer rather than a value that ignores it.
  SEEDED_MULTIPLIERS = { "1-2" => 0.5, "3-6" => 6.0, "7+" => 20.0 }.freeze

  belongs_to :store

  validates :size_class, presence: true, uniqueness: { scope: :store_id }
  validates :sample_count, numericality: { greater_than_or_equal_to: 0 }

  # @return [Boolean] whether the learned threshold should override the seed
  def confident?
    sample_count >= MINIMUM_SAMPLES && ewma_seconds.present?
  end

  # @return [Float] the learned "unusually slow" cutoff for this size class
  def threshold_seconds
    ewma_seconds + (THRESHOLD_Z * Math.sqrt(ewma_variance.to_f))
  end
end
