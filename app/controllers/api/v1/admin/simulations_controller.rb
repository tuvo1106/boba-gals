module Api
  module V1
    module Admin
      # POST /api/v1/admin/simulations (§9.1, §10.1)
      #
      # Option (A) from §10.1, the recommended one: scheduler and simulator both
      # in Ruby, the dashboard posts a scenario and renders returned metrics.
      # That guarantees one implementation — a client-side port would need 20
      # golden tests asserting identical dispatch sequences, and would still
      # drift.
      #
      # Behind the admin session (§13.4) because a run is unbounded compute, and
      # because the scenario knobs are the same ones that tune the live store.
      class SimulationsController < BaseController
        # A full day is a few thousand capsules; no screen renders that legibly,
        # and shipping it wastes far more bandwidth than the metrics. The ribbon
        # asks for a window (§10.6).
        DEFAULT_WINDOW_SECONDS = 1_800

        def create
          scenario = build_scenario
          world = ::Simulator.simulate(scenario)
          metrics = ::Simulator::Metrics.new(
            orders: world.completed, seconds: world.clock,
            stations: scenario.stations, reneged: world.reneged, remakes: world.remakes
          )

          render json: {
            # "Every run must display its seed" (§10.6) — a result nobody can
            # replay is an anecdote.
            seed: scenario.seed,
            stations: scenario.stations,
            metrics: metrics.to_h,
            window: { from: window.begin, to: window.end },
            timeline: world.timeline(window: window),
            # Lets the dashboard jump to any order without re-running the day.
            order_spans: world.order_spans
          }
        end

        private

        def build_scenario
          ::Simulator::Scenario.new(
            seed: params.fetch(:seed, 1).to_i,
            stations: params.fetch(:stations, 3).to_i,
            demand_multiplier: params.fetch(:demand_multiplier, 1.0).to_f,
            large_order_rate: params[:large_order_rate]&.to_f,
            scheduler_config: scheduler_config
          )
        end

        # Only the scheduler's own keys, symbolized. Reuses the admin config
        # allowlist so a simulation cannot be asked to run a policy the store
        # could never be set to (§14.6).
        def scheduler_config
          raw = params[:scheduler_config]
          return {} unless raw.respond_to?(:to_unsafe_h)

          raw.to_unsafe_h.symbolize_keys.slice(*UpdateSchedulerConfig::SCHEMA.keys.map(&:to_sym))
        end

        def window
          from = params.fetch(:window_from, 0).to_f
          span = params.fetch(:window_seconds, DEFAULT_WINDOW_SECONDS).to_f

          from..(from + span)
        end
      end
    end
  end
end
