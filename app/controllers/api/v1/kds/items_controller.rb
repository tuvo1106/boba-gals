module Api
  module V1
    module Kds
      class ItemsController < BaseController
        # POST /api/v1/kds/items/start
        #
        # Takes no item id: the barista taps "start next" and the server decides
        # which drink that is. That is what lets build step 5 swap FIFO for the
        # scheduler without the client changing at all, and it is why two
        # simultaneous taps cannot collide on one row (§8).
        def start
          item = ClaimNextDrink.new.call(station: current_station, barista: current_barista)

          return render json: { error: "nothing queued" }, status: :not_found if item.nil?

          render json: KitchenQueue.serialize(item), status: :ok
        end

        # POST /api/v1/kds/items/:id/finish
        def finish
          result = FinishDrink.new.call(find_item!)

          return unprocessable(result.error) unless result.success?

          render json: KitchenQueue.serialize(result.item)
        end

        # POST /api/v1/kds/items/:id/undo — reverts the last transition (§9.4).
        def undo
          result = UndoLastAction.new.call(find_item!)

          return unprocessable(result.error) unless result.success?

          render json: KitchenQueue.serialize(result.item)
        end
      end
    end
  end
end
