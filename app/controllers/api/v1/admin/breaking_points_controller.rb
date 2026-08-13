module Api
  module V1
    module Admin
      # POST /api/v1/admin/breaking_points (§10.5 #4)
      #
      # "Breaking point: raise the demand multiplier until p90 exceeds 15 min.
      # That number is the store's real capacity."
      #
      # Its own endpoint for the same reason `ablations`, `quantum_sweeps`,
      # and `staffing_curves` are: `Simulator::BreakingPoint::POINTS.size`
      # runs per seed, and a capacity figure plus a curve rather than a
      # timeline. Behind the admin session for the same reason as the other
      # three — unbounded compute.
      class BreakingPointsController < BaseController
        def create
          result = ::Simulator::BreakingPoint.call(
            seed: seed, stations: stations, seeds: seeds, target_seconds: target_seconds
          )

          render json: {
            # "Every run must display its seed" (§10.6).
            seed: seed,
            seeds: seeds,
            stations: stations,
            target_seconds: target_seconds,
            points: result[:points],
            capacity: result[:capacity]
          }
        end

        private

        def seed
          params.fetch(:seed, 1).to_i
        end

        def stations
          params.fetch(:stations, 3).to_i
        end

        # Clamped here as well as in `BreakingPoint`, so the response can
        # report the number actually used rather than the number asked for.
        def seeds
          params.fetch(:seeds, 1).to_i.clamp(1, ::Simulator::BreakingPoint::MAX_SEEDS)
        end

        def target_seconds
          params.fetch(:target_seconds, ::Simulator::BreakingPoint::TARGET_SECONDS).to_f
        end
      end
    end
  end
end
