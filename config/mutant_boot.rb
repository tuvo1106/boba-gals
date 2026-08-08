# Loads the scheduler for mutant without booting Rails.
#
# `app/scheduler/**` must not require Rails (CLAUDE.md, §6.2). Booting it here
# would make every mutant pay Rails' load time and would quietly hide a
# violation of that constraint.
root = File.expand_path("../app/scheduler", __dir__)

require "#{root}/scheduler/config"
require "#{root}/scheduler/item"
require "#{root}/scheduler/flow"
require "#{root}/scheduler/state"
require "#{root}/scheduler"
