FactoryBot.define do
  factory :store do
    sequence(:name) { |n| "Boba Gals #{n}" }
    timezone { "America/Los_Angeles" }
    station_count { 3 }
    accepting_orders { true }

    trait :closed do
      accepting_orders { false }
    end

    trait :with_stations do
      transient { station_count_to_create { 3 } }

      after(:create) do |store, evaluator|
        evaluator.station_count_to_create.times do |i|
          create(:station, store: store, name: "Bar #{i + 1}")
        end
      end
    end
  end

  factory :station do
    store
    sequence(:name) { |n| "Bar #{n}" }
    active { true }

    trait :inactive do
      active { false }
    end
  end

  factory :barista do
    store
    sequence(:name) { |n| "Barista #{n}" }
    pin { "1234" }
  end

  factory :admin_user do
    sequence(:email) { |n| "admin#{n}@bobagals.test" }
    password { "correct-horse-battery-staple" }
  end
end
