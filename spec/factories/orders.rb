FactoryBot.define do
  factory :order do
    store
    source { "kiosk" }
    status { "placed" }
    placed_at { Time.current }
    customer_first_name { "Sam" }
    pickup_code { PickupCode.generate }
    total_cents { 550 }

    trait :web do
      source { "web" }
      customer_phone { "+15555550123" }
    end

    trait :promised do
      promised_at { 2.hours.from_now }
    end

    trait :ready do
      status { "ready" }
      ready_at { Time.current }
    end

    trait :picked_up do
      status { "picked_up" }
      ready_at { 5.minutes.ago }
      picked_up_at { Time.current }
    end

    # A catering-sized order — the case the whole design exists for (§2).
    trait :large do
      transient { drink_count { 15 } }

      after(:create) do |order, evaluator|
        menu_item = create(:menu_item, store: order.store)
        evaluator.drink_count.times do |i|
          create(:order_item, order: order, menu_item: menu_item, sequence: i + 1)
        end
      end
    end
  end

  factory :order_item do
    order
    menu_item { association :menu_item, store: order.store }
    label { menu_item.name }
    prep_seconds { menu_item.base_prep_seconds }
    status { "queued" }
    queued_at { Time.current }
    sequence(:sequence) { |n| n }

    trait :in_progress do
      status { "in_progress" }
      started_at { Time.current }
      station { association :station, store: order.store }
      barista { association :barista, store: order.store }
    end

    trait :finished do
      status { "finished" }
      started_at { 90.seconds.ago }
      finished_at { Time.current }
    end

    trait :remake do
      remake_of { association :order_item, order: order }
      remake_reason { "spill" }
    end
  end
end
