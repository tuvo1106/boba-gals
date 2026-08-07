# Lets examples call `build(:order)` instead of `FactoryBot.build(:order)`.
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
