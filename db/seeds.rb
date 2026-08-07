# Seeds a single store with a menu whose prep times actually differ.
#
# That spread is the point: §1 names 40s for a Thai tea and 95s for a brown sugar
# pearl drink, and the whole design exists because those are not the same unit of
# work. A menu where everything takes 60s would make FIFO look fine and hide the
# problem the scheduler is built to solve.

store = Store.find_or_create_by!(name: "Boba Gals") do |s|
  s.timezone = "America/Los_Angeles"
  s.station_count = 3
  s.accepting_orders = true
end

3.times { |i| Station.find_or_create_by!(store:, name: "Bar #{i + 1}") }

Barista.find_or_create_by!(store:, name: "Sam") { |b| b.pin = "1234" }
Barista.find_or_create_by!(store:, name: "Alex") { |b| b.pin = "5678" }

AdminUser.find_or_create_by!(email: "admin@bobagals.test") do |u|
  u.password = ENV.fetch("SEED_ADMIN_PASSWORD", "changeme-in-any-real-deploy")
end

MENU = [
  { name: "Classic Milk Tea",     category: "milk_tea",   prep: 45, price: 550 },
  { name: "Thai Tea",             category: "milk_tea",   prep: 40, price: 575 },
  { name: "Taro Milk Tea",        category: "milk_tea",   prep: 55, price: 625 },
  { name: "Brown Sugar Pearl",    category: "specialty",  prep: 95, price: 725 },
  { name: "Matcha Latte",         category: "specialty",  prep: 70, price: 675 },
  { name: "Passionfruit Green",   category: "fruit_tea",  prep: 50, price: 600 },
  { name: "Strawberry Green Tea", category: "fruit_tea",  prep: 60, price: 625 },
  { name: "Mango Slush",          category: "slush",      prep: 85, price: 700 },
  { name: "Taro Slush",           category: "slush",      prep: 90, price: 700 }
].freeze

MENU.each_with_index do |row, index|
  item = MenuItem.find_or_create_by!(store:, name: row[:name]) do |m|
    m.category = row[:category]
    m.base_prep_seconds = row[:prep]
    m.price_cents = row[:price]
    m.position = index
  end

  # Sweetness and Ice are required single-select; both are free and instant.
  sweetness = OptionGroup.find_or_create_by!(menu_item: item, name: "Sweetness") do |g|
    g.min_select = 1
    g.max_select = 1
  end
  [ "100%", "75%", "50%", "25%", "0%" ].each do |level|
    Option.find_or_create_by!(option_group: sweetness, name: level)
  end

  ice = OptionGroup.find_or_create_by!(menu_item: item, name: "Ice") do |g|
    g.min_select = 1
    g.max_select = 1
  end
  [ "Regular ice", "Less ice", "No ice" ].each do |level|
    Option.find_or_create_by!(option_group: ice, name: level)
  end

  # Toppings are optional and multi-select, and the only group that moves
  # prep_seconds — which is what makes two orders of the same drink genuinely
  # different work (§4.1).
  toppings = OptionGroup.find_or_create_by!(menu_item: item, name: "Toppings") do |g|
    g.min_select = 0
    g.max_select = 3
  end
  [
    { name: "Boba pearls",   price: 75,  delta: 15 },
    { name: "Extra pearls",  price: 100, delta: 15 },
    { name: "Grass jelly",   price: 75,  delta: 10 },
    { name: "Pudding",       price: 75,  delta: 10 },
    { name: "Aloe vera",     price: 75,  delta: 10 }
  ].each do |topping|
    Option.find_or_create_by!(option_group: toppings, name: topping[:name]) do |o|
      o.price_cents = topping[:price]
      o.prep_seconds_delta = topping[:delta]
    end
  end
end

puts "Seeded #{store.name}: #{store.menu_items.count} menu items, " \
     "#{store.stations.count} stations, #{store.baristas.count} baristas"
