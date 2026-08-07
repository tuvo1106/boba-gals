# `travel_to` / `freeze_time` in every example.
#
# docs/testing.md forbids `sleep` in specs, and several behaviors here are
# defined purely in terms of elapsed time — the 60-second undo window (§9.4),
# the 12-hour station token (§13.3), the quality timer (§9.6). Those need a
# controllable clock, not a real one.
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end
