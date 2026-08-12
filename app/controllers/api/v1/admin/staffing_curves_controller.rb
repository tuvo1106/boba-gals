module Api
  module V1
    module Admin
      # POST /api/v1/admin/staffing_curves (§10.5 #3)
      #
      # "Staffing curve: for each hour, minimum stations holding p90 under
      # target. Output is an actual shift schedule."
      #
      # Its own endpoint for the same reason `ablations` and `quantum_sweeps`
      # are: `Simulator::StaffingCurve::STATIONS_TRIED.size` runs per seed,
      # and a shift schedule rather than a timeline. Behind the admin session
      # for the same reason as the other two — unbounded compute.
      class StaffingCurvesController < BaseController
        def create
          hours = ::Simulator::StaffingCurve.call(
            seed: seed, demand_multiplier: demand_multiplier, seeds: seeds, target_seconds: target_seconds
          )

          render json: {
            # "Every run must display its seed" (§10.6).
            seed: seed,
            seeds: seeds,
            demand_multiplier: demand_multiplier,
            target_seconds: target_seconds,
            hours: hours
          }
        end

        private

        def seed
          params.fetch(:seed, 1).to_i
        end

        def demand_multiplier
          params.fetch(:demand_multiplier, 1.0).to_f
        end

        # Clamped here as well as in `StaffingCurve`, so the response can
        # report the number actually used rather than the number asked for.
        def seeds
          params.fetch(:seeds, 1).to_i.clamp(1, ::Simulator::StaffingCurve::MAX_SEEDS)
        end

        def target_seconds
          params.fetch(:target_seconds, ::Simulator::StaffingCurve::DEFAULT_TARGET_SECONDS).to_f
        end
      end
    end
  end
end
