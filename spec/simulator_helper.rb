require "spec_helper"
require "benchmark"

# Like the gem's own spec_helper, this deliberately does not load Rails. The
# simulator is pure Ruby over the pure scheduler (§10.1), and a run of thousands
# of shifts must not pay Rails' boot cost.
root = File.expand_path("..", __dir__)

# One `require` instead of five hand-ordered paths: the gem's entry point owns
# its own load order now (ADR-0033), and bundler puts it on the load path.
require "deficit_scheduler"
require "#{root}/app/services/build_scheduler_config"
require "#{root}/app/simulator/simulator/rng"
require "#{root}/app/simulator/simulator/scenario"
require "#{root}/app/simulator/simulator/event_queue"
require "#{root}/app/simulator/simulator/metrics"
require "#{root}/app/simulator/simulator/projection"
require "#{root}/app/simulator/simulator"

# Scenario#config and Metrics#by_size_class use ActiveSupport conveniences that
# are not worth loading Rails for.
unless Hash.method_defined?(:except)
  class Hash
    def except(*keys) = reject { |k, _| keys.include?(k) }
  end
end

unless Array.method_defined?(:index_with)
  class Array
    def index_with = to_h { |k| [ k, yield(k) ] }
  end
end
