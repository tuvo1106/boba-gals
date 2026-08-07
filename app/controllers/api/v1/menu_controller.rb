module Api
  module V1
    # GET /api/v1/menu — public (§13.1).
    class MenuController < BaseController
      def index
        render json: MenuSerializer.call(current_store)
      end
    end
  end
end
