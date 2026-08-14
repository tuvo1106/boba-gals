# Deficit round robin work scheduling as a pure function.
#
# Required in dependency order rather than autoloaded: this gem has no runtime
# dependencies at all (see the gemspec), which is what enforces that the
# scheduler never reaches for Rails — a spec helper that happens not to load
# ActiveSupport is discipline, a gemspec that declares nothing is a boundary.
require_relative "deficit_scheduler/config"
require_relative "deficit_scheduler/item"
require_relative "deficit_scheduler/flow"
require_relative "deficit_scheduler/state"
require_relative "deficit_scheduler/scheduler"
