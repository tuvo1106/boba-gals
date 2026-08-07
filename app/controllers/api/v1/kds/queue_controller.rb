module Api
  module V1
    module Kds
      # GET /api/v1/kds/queue — in-progress plus next-up, scheduler-ordered (§9.1).
      #
      # The same payload KitchenChannel pushes, so a client that polls and a
      # client that subscribes render identically.
      class QueueController < BaseController
        def show
          render json: KitchenQueue.call(current_store)
        end
      end
    end
  end
end
