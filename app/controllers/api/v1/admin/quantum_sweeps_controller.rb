module Api
  module V1
    module Admin
      # POST /api/v1/admin/quantum_sweeps (§10.5)
      #
      # "Quantum sweep: 30s → 400s, plot small-order p90 and large-order p90
      # together. The crossover is your setting."
      #
      # Its own endpoint rather than a parameter on `simulations`, for the same
      # reason `ablations` is: it returns ten metric sets and no timeline — a
      # different shape, not a variant. Behind the admin session for the same
      # reason as `ablations` — ten runs per seed is unbounded compute.
      class QuantumSweepsController < BaseController
        def create
          points = ::Simulator::QuantumSweep.call(
            seed: seed, stations: stations, demand_multiplier: demand_multiplier, seeds: seeds
          )

          render json: {
            # "Every run must display its seed" (§10.6).
            seed: seed,
            seeds: seeds,
            stations: stations,
            demand_multiplier: demand_multiplier,
            points: points
          }
        end

        private

        def seed
          params.fetch(:seed, 1).to_i
        end

        def stations
          params.fetch(:stations, 3).to_i
        end

        def demand_multiplier
          params.fetch(:demand_multiplier, 1.0).to_f
        end

        # Clamped here as well as in `QuantumSweep`, so the response can report
        # the number actually used rather than the number asked for.
        def seeds
          params.fetch(:seeds, 1).to_i.clamp(1, ::Simulator::QuantumSweep::MAX_SEEDS)
        end
      end
    end
  end
end
