require "spec_helper"
require "benchmark"

# Like spec/scheduler_helper.rb, this deliberately does not load Rails. The
# simulator is pure Ruby over the pure scheduler (§10.1), and a run of thousands
# of shifts must not pay Rails' boot cost.
root = File.expand_path("..", __dir__)

require "#{root}/app/scheduler/scheduler/config"
require "#{root}/app/scheduler/scheduler/item"
require "#{root}/app/scheduler/scheduler/flow"
require "#{root}/app/scheduler/scheduler/state"
require "#{root}/app/scheduler/scheduler"
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
