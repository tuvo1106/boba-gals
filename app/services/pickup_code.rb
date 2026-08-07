# Generates the 4-character pickup code that doubles as the capability token for
# GET /api/v1/orders/:pickup_code (§13.1).
#
# The alphabet excludes characters people misread aloud or off a receipt, which
# matters because staff call these across a counter.
#
# NOTE ON §13.1: the design says "4 chars from a 30-char unambiguous alphabet
# (no 0/O/1/I/L/B/8) ≈ 810k codes". Those two statements disagree — removing
# seven characters from the 36 alphanumerics leaves 29, not 30, so the space is
# 29^4 = 707,281 rather than 810,000. The exclusion list is the substantive
# requirement (unambiguous characters), so it is implemented as written and the
# count corrected. 707k is still far past the point where per-IP throttling
# makes enumeration pointless.
class PickupCode
  AMBIGUOUS = %w[0 O 1 I L B 8].freeze
  ALPHABET = (("A".."Z").to_a + ("0".."9").to_a - AMBIGUOUS).freeze
  LENGTH = 4

  # Codes are unique per store per day (idx_pickup_code_daily), so a collision
  # is possible and cheap to retry. Exhausting this many attempts against a 707k
  # space means something is badly wrong, and failing loudly beats looping.
  MAX_ATTEMPTS = 20

  class ExhaustedError < StandardError; end

  # @return [String] e.g. "K7QF"
  def self.generate
    Array.new(LENGTH) { ALPHABET.sample(random: SecureRandom) }.join
  end

  # @param store [Store]
  # @param on [Date] the business day the code must be unique within
  # @return [String] a code not currently in use for that store and day
  # @raise [ExhaustedError] if no free code is found in MAX_ATTEMPTS
  def self.generate_unique(store:, on: Date.current)
    MAX_ATTEMPTS.times do
      code = generate
      return code unless taken?(store:, code:, on:)
    end

    raise ExhaustedError, "no free pickup code for store #{store.id} on #{on} after #{MAX_ATTEMPTS} attempts"
  end

  # @return [Boolean]
  def self.taken?(store:, code:, on: Date.current)
    store.orders
         .where(pickup_code: code)
         .where("placed_at::date = ?", on)
         .exists?
  end
end
