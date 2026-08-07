module Api
  module V1
    module Admin
      class PrepTimeStatsController < BaseController
        # GET /api/v1/admin/prep_time_stats
        #
        # The learned prep times (§7.3) next to the seeded guesses they will
        # eventually override. Empty until build step 7 fills it in — it ships
        # now because "is the EWMA converging" is the first question anyone asks
        # when the board's ETA looks wrong, and answering it should not require
        # a console.
        def index
          stats = PrepTimeStat.joins(:menu_item)
                              .where(menu_items: { store_id: current_store.id })
                              .includes(:menu_item)
                              .order("menu_items.name")

          render json: { items: stats.map { |stat| serialize(stat) } }
        end

        private

        def serialize(stat)
          {
            menu_item_id: stat.menu_item_id,
            name: stat.menu_item.name,
            seeded_prep_seconds: stat.menu_item.base_prep_seconds,
            ewma_seconds: stat.ewma_seconds,
            ewma_variance: stat.ewma_variance,
            sample_count: stat.sample_count,
            # Below MINIMUM_SAMPLES the seeded value still wins (§7.3). Saying
            # so explicitly stops anyone reading a 3-sample average as truth.
            confident: stat.confident?,
            minimum_samples: PrepTimeStat::MINIMUM_SAMPLES
          }
        end
      end
    end
  end
end
