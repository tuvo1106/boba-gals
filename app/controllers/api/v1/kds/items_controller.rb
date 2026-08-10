module Api
  module V1
    module Kds
      class ItemsController < BaseController
        # POST /api/v1/kds/items/start
        #
        # Takes no item id: the barista taps "start next" and the server decides
        # which drink that is. That is what let DRR replace FIFO at build step 5
        # without the client changing at all, and it is why two simultaneous
        # taps cannot collide on one row (§8).
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

        # POST /api/v1/kds/items/:id/fail — `{ reason }` creates a remake (§9.1).
        #
        # Not a variant of undo. Undo rewinds a mistap within 60 seconds; this
        # records that a real drink was really made wrong, and the replacement
        # is a new row because `finished` is terminal (§5.2).
        def fail
          result = FailDrink.new.call(find_item!, reason: params[:reason].to_s)

          return unprocessable(result.error) unless result.success?

          # The *remake* is what the barista now has to make, so that is what
          # comes back — returning the failed drink would put a dead row on
          # screen.
          render json: KitchenQueue.serialize(result.remake)
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
