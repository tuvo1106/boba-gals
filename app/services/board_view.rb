# The customer board: what is being made, and what is ready (§9.2, §9.5).
#
# Privacy is locked (§3): first name plus pickup code, nothing else. Two Sarahs
# are disambiguated by code, never by a surname initial — which is also why this
# serializer has no branch for that case and must not grow one.
class BoardView
  # "Items persist for 90 seconds after `picked_up_at` so a customer walking up
  # doesn't see their name vanish." (§9.5)
  PICKED_UP_PERSISTENCE = 90.seconds

  # A ready row is retired five minutes after `ready_at` whether or not anyone
  # collected it (ADR-0005). Pickup is not tracked, so this is the only thing
  # that keeps the column from growing for the length of a shift.
  #
  # Sized from §10.3: pickup delay averages 100s at the kiosk and 180s on the
  # web, so five minutes is well past when most customers have walked up. At the
  # peak arrival rate of 52 orders/hour it holds the column near four rows. Ten
  # minutes would hold nine, which is the whole column at 15-foot type with
  # Making competing for the same screen.
  #
  # Retiring a row is not a state change: the order stays `ready` until the
  # 45-minute abandoned sweep (§5.1).
  READY_BOARD_TTL = 5.minutes

  # `partially_ready` belongs in Making: some of the order is done, but the
  # customer cannot collect it yet, and telling them otherwise sends them to the
  # counter for a drink that is still in a shaker.
  MAKING_STATUSES = %w[placed in_progress partially_ready].freeze

  # @param store [Store]
  # @param now [Time]
  # @return [Hash] the BoardChannel `board_update` payload
  def self.call(store, now: Time.current)
    new(store, now: now).call
  end

  def initialize(store, now: Time.current)
    @store = store
    @now = now
  end

  # @return [Hash]
  def call
    {
      type: "board_update",
      # Additive to the §9.2 sketch. v1 serves a single store and resolves it
      # server-side (Api::V1::BaseController#current_store), so a board screen
      # has no other way to learn which store to subscribe to — and hard-coding
      # it into the wall display's URL is a configuration step that will be got
      # wrong (§16, multi-store).
      store_id: @store.id,
      making: making,
      ready: ready
    }
  end

  private

  def making
    estimates = ProjectEta.for_open_orders(@store, now: @now)

    rows = orders(MAKING_STATUSES).map do |order|
      {
        first_name: order.customer_first_name,
        pickup_code: order.pickup_code,
        items: order.order_items.sort_by(&:sequence).map(&:label),
        eta_seconds: estimates.fetch(order.id, 0)
      }
    end

    # Soonest first. A board is scanned, not read: the rows about to be called
    # belong where eyes land, and it puts an order-ahead promised two hours out
    # at the bottom instead of pinned to the top by its placement time.
    rows.sort_by { |row| [ row[:eta_seconds], row[:pickup_code] ] }
  end

  def ready
    rows = ready_orders.map do |order|
      picked_up_ago = (@now - order.picked_up_at).round if order.picked_up_at

      {
        first_name: order.customer_first_name,
        pickup_code: order.pickup_code,
        ready_since_seconds: order.ready_at ? (@now - order.ready_at).round : 0,
        # Additive to the §9.2 sketch, and always nil for now: nothing in the
        # live application sets `picked_up_at` (ADR-0005). It is here so the
        # client can retire a collected row on its own clock at 90s rather than
        # waiting for whenever the next broadcast happens to arrive — which in a
        # quiet store can be minutes.
        picked_up_seconds_ago: picked_up_ago
      }
    end

    # Most recently ready at the top — that is the name just called out loud.
    rows.sort_by { |row| row[:ready_since_seconds] }
  end

  def orders(statuses)
    @store.orders.where(status: statuses).includes(:order_items).to_a
  end

  # Both windows are applied in SQL, not in Ruby. `picked_up` is terminal and
  # accumulates for the life of the store, so filtering after loading would mean
  # reading every order the shop has ever sold on every broadcast.
  def ready_orders
    collected = @store.orders.where(status: "picked_up")
                      .where(picked_up_at: (@now - PICKED_UP_PERSISTENCE)..)

    uncollected = @store.orders.where(status: "ready")
                        .where(ready_at: (@now - READY_BOARD_TTL)..)

    uncollected.or(collected).to_a
  end
end
