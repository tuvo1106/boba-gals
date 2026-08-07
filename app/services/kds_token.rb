# The KDS station token (§13.3).
#
# A barista authenticates once with a PIN and a station, and gets back a signed
# token carrying who and where they are. It is sent as `Authorization: Bearer`
# on every /kds/* call and as a subscription param on KitchenChannel — and it is
# verified in both places, because a REST-only check leaves the websocket open.
#
# Signed, not encrypted: the contents are not secret, they just must not be
# forgeable. Rails' message verifier handles expiry itself, so an expired token
# fails verification rather than being decoded and checked afterwards.
class KdsToken
  TTL = 12.hours

  Claims = Struct.new(:barista_id, :station_id, :store_id, keyword_init: true)

  class << self
    # @param barista [Barista]
    # @param station [Station]
    # @return [String] a signed token valid for TTL
    def issue(barista:, station:)
      verifier.generate(
        { "barista_id" => barista.id, "station_id" => station.id, "store_id" => station.store_id },
        expires_in: TTL
      )
    end

    # @param token [String, nil]
    # @return [KdsToken::Claims, nil] nil when missing, tampered with, or expired
    def verify(token)
      return nil if token.blank?

      payload = verifier.verified(token)
      return nil if payload.nil?

      Claims.new(
        barista_id: payload["barista_id"],
        station_id: payload["station_id"],
        store_id: payload["store_id"]
      )
    end

    private

    def verifier
      Rails.application.message_verifier(:kds)
    end
  end
end
