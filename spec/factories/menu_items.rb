FactoryBot.define do
  factory :menu_item do
    store
    sequence(:name) { |n| "Drink #{n}" }
    category { "milk_tea" }
    base_prep_seconds { 45 }
    price_cents { 550 }
    available { true }

    # The two drinks §1 names explicitly. Prep times that differ by more than
    # 2x are what make the fairness problem real, so tests reach for these
    # rather than inventing arbitrary numbers.
    trait :thai_tea do
      name { "Thai Tea" }
      base_prep_seconds { 40 }
    end

    trait :brown_sugar_pearl do
      name { "Brown Sugar Pearl" }
      category { "specialty" }
      base_prep_seconds { 95 }
      price_cents { 725 }
    end

    trait :unavailable do
      available { false }
    end

    # A required single-select group plus an optional multi-select topping group
    # that moves prep_seconds — the shape the real menu uses.
    trait :with_options do
      after(:create) do |item|
        sweetness = create(:option_group, menu_item: item, name: "Sweetness", min_select: 1, max_select: 1)
        create(:option, option_group: sweetness, name: "100%")
        create(:option, option_group: sweetness, name: "50%")

        toppings = create(:option_group, menu_item: item, name: "Toppings", min_select: 0, max_select: 2)
        create(:option, option_group: toppings, name: "Boba pearls", price_cents: 75, prep_seconds_delta: 15)
        create(:option, option_group: toppings, name: "Grass jelly", price_cents: 75, prep_seconds_delta: 10)
      end
    end
  end

  factory :option_group do
    menu_item
    sequence(:name) { |n| "Group #{n}" }
    min_select { 0 }
    max_select { 1 }
  end

  factory :option do
    option_group
    sequence(:name) { |n| "Option #{n}" }
    price_cents { 0 }
    prep_seconds_delta { 0 }
  end
end
