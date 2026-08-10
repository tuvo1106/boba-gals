FactoryBot.define do
  # The EWMA of observed prep durations (§7.3), written by `RecordPrepTime` and
  # read by `ProjectEta` once `confident?`.
  factory :prep_time_stat do
    menu_item
    ewma_seconds { 45.0 }
    ewma_variance { 12.0 }
    sample_count { 1 }

    # §7.3: below MINIMUM_SAMPLES the seeded base_prep_seconds still wins.
    trait :confident do
      sample_count { PrepTimeStat::MINIMUM_SAMPLES }
    end
  end
end
