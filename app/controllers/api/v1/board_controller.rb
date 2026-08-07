module Api
  module V1
    class BoardController < BaseController
      # GET /api/v1/board — public (§13.1).
      #
      # The board screen subscribes to BoardChannel for live updates; this is
      # what it renders from on first paint, and what it falls back to if the
      # websocket is unavailable.
      def show
        render json: BoardView.call(current_store)
      end
    end
  end
end
