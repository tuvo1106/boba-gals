module Api
  module V1
    module Kds
      # POST /api/v1/kds/session — barista PIN login (§13.3).
      #
      # Rate-limited to 10/min per IP (§13.2): PINs are four digits, so this is
      # the one endpoint where brute force is genuinely cheap.
      class SessionsController < Api::V1::BaseController
        def create
          station = Station.active.find_by(id: params[:station_id])
          return unauthorized if station.nil?

          barista = station.store.baristas.find { |b| b.authenticate_pin(params[:barista_pin].to_s) }
          return unauthorized if barista.nil?

          render json: {
            token: KdsToken.issue(barista: barista, station: station),
            expires_in: KdsToken::TTL.to_i,
            barista: { id: barista.id, name: barista.name },
            station: { id: station.id, name: station.name },
            # The client needs this to subscribe: KitchenChannel rejects a
            # subscription whose store_id does not match the token's (§13.3),
            # and without it here a client can only guess. Guessing the station
            # id happens to work for station 1 of store 1 and nothing else.
            store: { id: station.store_id, name: station.store.name }
          }, status: :created
        end

        private

        # Deliberately identical whether the station or the PIN was wrong — a
        # distinguishing message would let someone enumerate valid stations.
        def unauthorized
          render json: { error: "invalid station or PIN" }, status: :unauthorized
        end
      end
    end
  end
end
