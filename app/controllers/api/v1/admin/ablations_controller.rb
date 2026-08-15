module Api
  module V1
    module Admin
      # POST /api/v1/admin/ablations (§10.5, §10.6)
      #
      # "Ablation on a fixed seed: FIFO → DRR → DRR+aging → DRR+aging+cohesion.
      # Four bars, one chart. This is the proof the design works."
      #
      # Plus §6.3's two simulator-only comparison arms, `rr` and `sjf` — see
      # `Simulator::Ablation` for why they belong on the same chart and why one
      # of them is drawn apart from it.
      #
      # Behind the admin session for the same reason as `simulations` (§13.4): a
      # run is unbounded compute, and this one is six of them per seed.
      class AblationsController < BaseController
        def create
          arms = ::Simulator::Ablation.call(
            seed: seed, stations: stations, demand_multiplier: demand_multiplier,
            seeds: seeds, quantum: quantum
          )

          render json: {
            # Everything needed to reproduce the chart. "Every run must display
            # its seed" (§10.6) applies four times over here — a bar chart
            # comparing schedulers is worthless if nobody can re-run it.
            seed: seed,
            seeds: seeds,
            stations: stations,
            demand_multiplier: demand_multiplier,
            quantum: quantum,
            arms: arms
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

        # Clamped here as well as in `Ablation`, so the response can report the
        # number actually used rather than the number asked for.
        def seeds
          params.fetch(:seeds, 1).to_i.clamp(1, ::Simulator::Ablation::MAX_SEEDS)
        end

        # Optional: lets the ablation be read at whatever quantum the sweep
        # settled on, rather than only at the default.
        #
        # Clamped to the same range the store-facing path enforces
        # (`UpdateSchedulerConfig::SCHEMA`), and for a sharper reason than
        # tidiness: `params[:quantum].to_i` turns `0`, `-5` and the typo
        # `sixty` all into a quantum of zero, and a zero quantum means the
        # deficit never reaches any item's cost. The ring then spins until
        # `LIVELOCK_GUARD` trips at 10,000 rounds and raises — a 500, after
        # 10,000 `priority_ring` sorts per arm across six arms. Clamping keeps
        # a mistyped sweep a readable result rather than a stack trace, the
        # same way `seeds` above is clamped rather than trusted.
        QUANTUM_RANGE = (UpdateSchedulerConfig::SCHEMA.dig("quantum", :min)..
                         UpdateSchedulerConfig::SCHEMA.dig("quantum", :max)).freeze

        def quantum
          params[:quantum].presence&.to_i&.clamp(QUANTUM_RANGE)
        end
      end
    end
  end
end
