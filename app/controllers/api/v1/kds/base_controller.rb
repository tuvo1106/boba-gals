module Api
  module V1
    module Kds
      # Every /kds/* endpoint requires a station token (§13.3).
      class BaseController < Api::V1::BaseController
        before_action :authenticate_station!

        private

        def authenticate_station!
          @claims = KdsToken.verify(bearer_token)

          return render json: { error: "invalid or expired station token" }, status: :unauthorized if @claims.nil?

          # A token is only as good as the station it names. `KdsToken::TTL` is
          # 12 hours and `SessionsController#create` deliberately issues only
          # against `Station.active`, but nothing re-checked that afterwards —
          # so closing a bar mid-shift did not close it. `Station#recompute_store_eta`
          # would re-project every ETA against the smaller `active_stations`
          # while the tablet at that bar kept claiming drinks, leaving the board
          # quoting from a capacity that did not match who was working. The only
          # way to take a station out of service was to unplug it.
          return if current_station&.active?

          render json: { error: "this station is no longer in service" }, status: :unauthorized
        end

        def bearer_token
          request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
        end

        def current_barista
          @current_barista ||= Barista.find(@claims.barista_id)
        end

        # `find_by`, not `find` — `authenticate_station!` asks whether the
        # station is still in service and needs an answer, not an exception, for
        # a station row that has since been deleted.
        def current_station
          @current_station ||= Station.find_by(id: @claims.station_id)
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
