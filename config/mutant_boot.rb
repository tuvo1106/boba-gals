# Loads the scheduler for mutant without booting Rails.
#
# The scheduler must not require Rails (ADR-0033). Booting it here would make
# every mutant pay Rails' load time and would quietly hide a violation of that
# constraint.
#
# The gem's `lib/` is added explicitly rather than relying on bundler, because
# mutant is invoked from the repo root against a gem that is not otherwise on
# the load path at boot time.
$LOAD_PATH.unshift File.expand_path("../gems/deficit_scheduler/lib", __dir__)

require "deficit_scheduler"
