FactoryBot.define do
  # The EWMA of an order's ready_at - first_ready_at spread, per size class
  # (§9.6, #80), written by `RecordQualitySpread` and read by
  # `SweepQualityBreaches` once `confident?`.
  factory :quality_spread_stat do
    store
    size_class { "3-6" }
    ewma_seconds { 1_200.0 }
    ewma_variance { 400.0 }
    sample_count { 1 }

    # Below MINIMUM_SAMPLES the seeded multiplier over quality_limit_seconds
    # still wins (#80).
    trait :confident do
      sample_count { QualitySpreadStat::MINIMUM_SAMPLES }
    end
  end
end
