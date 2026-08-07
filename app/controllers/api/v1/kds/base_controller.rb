module Api
  module V1
    module Kds
      # Every /kds/* endpoint requires a station token (§13.3).
      class BaseController < Api::V1::BaseController
        before_action :authenticate_station!

        private

        def authenticate_station!
          @claims = KdsToken.verify(bearer_token)

          render json: { error: "invalid or expired station token" }, status: :unauthorized if @claims.nil?
        end

        def bearer_token
          request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
        end

        def current_barista
          @current_barista ||= Barista.find(@claims.barista_id)
        end

        def current_station
          @current_station ||= Station.find(@claims.station_id)
        end

        def current_store
          @current_store ||= Store.find(@claims.store_id)
        end

        # Scoped to the token's store, so a valid token cannot reach another
        # store's drinks.
        def find_item!
          OrderItem.joins(:order)
                   .where(orders: { store_id: @claims.store_id })
                   .find(params[:id])
        end
      end
    end
  end
end
