# Forward-projection wait estimate (DESIGN.md §7.1).
#
# "Run the same scheduler forward as a simulation against the current queue.
# Assign queued items to the next-free station; the projection yields
# `projected_start_at` and `projected_ready_at` per item. Order ETA = max over
# its items, multiplied by `eta_safety_factor`."
#
# This replaces `NaiveEta`'s `total_work / stations` (build step 3, ADR-0004),
# which has no idea that fair queuing reorders work: it quotes by queue position
# and so drifts the moment the quantum changes. Running the real
# `Scheduler.pick_next` is the only method that stays correct when scheduler
# parameters move, because the parameters are inputs to it rather than
# assumptions baked into a formula. It is the same rule §10.1 imposes on the
# simulator — project with the production scheduler or you are projecting a
# different shop.
#
# **This must never call `SchedulerStateStore#save`.** `pick_next` mutates the
# state it is given — drawing down deficits, advancing the ring pointer,
# shifting items off flow queues (§6.2). Those mutations are confined to the
# in-memory copy loaded here, and persisting them would mean that quoting a
# customer an ETA silently consumed the real queue's deficits and reordered
# what the kitchen makes next.
class ProjectEta
  # The projection is bounded by the queue: each iteration either dispatches a
  # drink or stops. This exists so a scheduler bug cannot hang a web request,
  # and is far above any realistic queue (§10.3's busiest hour is ~52 orders).
  MAX_DISPATCHES = 5_000

  class ProjectionOverflow < StandardError; end

  # @param store [Store]
  # @param now [Time] injected so a spec asserts against the clock it set up
  def initialize(store, now: Time.current)
    @store = store
    @now = now
  end

  # @param store [Store]
  # @return [Hash{Integer => Integer}] order id => estimated seconds until ready
  def self.for_open_orders(store, now: Time.current)
    new(store, now: now).for_open_orders
  end

  # The quote shown at ordering time (§7.3's "board customers trust"). Computed
  # after the order's drinks are queued, so it includes the work the customer
  # just created — see `CreateOrder`.
  #
  # @param store [Store]
  # @param order [Order]
  # @return [Integer] seconds until this order is ready
  def self.for_order(store, order, now: Time.current)
    new(store, now: now).for_open_orders.fetch(order.id, 0)
  end

  # @return [Hash{Integer => Integer}] order id => estimated seconds until ready
  def for_open_orders
    ready_at = project

    ready_at.transform_values { |time| with_safety(time - @now) }
  end

  # Per-item projection, which §7.2's board broadcast and §9.5's "Next up"
  # section both want in full rather than rolled up.
  #
  # @return [Hash{Integer => Hash}] item id => `{ start_at:, ready_at: }`
  def per_item
    @per_item ||= begin
      run
      @item_projection
    end
  end

  private

  # @return [Hash{Integer => Time}] order id => when its last drink is ready
  def project
    run

    @item_projection.each_with_object({}) do |(item_id, times), orders|
      order_id = @order_id_by_item.fetch(item_id)
      # §7.1: "Order ETA = max over its items." An order is ready when its
      # slowest drink is, not when its first one is.
      orders[order_id] = [ orders[order_id], times[:ready_at] ].compact.max
    end
  end

  def run
    return if @item_projection

    @item_projection = {}
    @order_id_by_item = {}

    # Drinks already being made are part of their order's ETA, and the
    # scheduler's flow set is built from `status = 'queued'` only (§6.5) — so
    # they are invisible to `pick_next` and have to be seeded here. Without
    # this, an order whose every drink is in progress falls out of the
    # projection entirely and the board shows it as ready while a barista is
    # still making it.
    seed_in_progress

    state = SchedulerStateStore.new(@store).load
    free_at = station_free_times
    dispatches = 0

    loop do
      dispatches += 1
      raise ProjectionOverflow, "projection exceeded #{MAX_DISPATCHES} dispatches" if dispatches > MAX_DISPATCHES

      # Whichever station frees first takes the next drink, and the projection
      # clock jumps to that moment — so aging and §6.2's backward scheduling are
      # evaluated at the time the decision would really be made.
      index = free_at.each_index.min_by { |i| free_at[i] }
      clock = free_at[index]

      picked = Scheduler.pick_next(state, clock)
      break if picked.nil?

      record(picked, clock)
      free_at[index] = clock + prep_seconds_for(picked[:item])
    end
  end

  def seed_in_progress
    in_progress_items.each do |item|
      start_at = item.started_at || @now

      @item_projection[item.id] = { start_at: start_at, ready_at: [ start_at + prep_seconds_for(item), @now ].max }
      @order_id_by_item[item.id] = item.order_id
    end
  end

  def record(picked, clock)
    item_id = picked[:item].id
    ready = clock + prep_seconds_for(picked[:item])

    @item_projection[item_id] = { start_at: clock, ready_at: ready }
    @order_id_by_item[item_id] = picked[:flow].id
  end

  # A drink already being made blocks its station until it is done, so the
  # projection cannot assume every station is free now — that is what would
  # quote the next customer a wait shorter than the drink already in the hand of
  # the barista who would make theirs.
  #
  # A drink running past its estimate frees its station now rather than in the
  # past, which is the honest reading: it is nearly done.
  def station_free_times
    busy = in_progress_by_station

    stations.map do |station|
      item = busy[station.id]
      next @now if item.nil? || item.started_at.nil?

      [ item.started_at + prep_seconds_for(item), @now ].max
    end
  end

  def in_progress_by_station
    in_progress_items.index_by(&:station_id)
  end

  def in_progress_items
    @in_progress_items ||= OrderItem.where(status: "in_progress")
                                    .joins(:order)
                                    .where(orders: { store_id: @store.id })
                                    .merge(Order.open)
                                    .to_a
  end

  # Runtime capacity is active stations, never the `station_count` seed column
  # (§4.1). A store with every station deactivated still owes an answer, and it
  # is projected as though one station were about to open rather than as
  # infinity — the same floor `NaiveEta` uses, for the same reason.
  def stations
    @stations ||= begin
      active = @store.active_stations.to_a
      active.presence || @store.stations.order(:id).first(1)
    end
  end

  # §7.3 will replace this with a learned EWMA per menu item. Reading it through
  # one method now means that change lands in one place rather than three.
  #
  # @param item [OrderItem, Scheduler::Item]
  def prep_seconds_for(item)
    item.prep_seconds
  end

  # §7.1: the projection is multiplied by `eta_safety_factor`. Quoting the raw
  # estimate means being late half the time, and a customer only notices the
  # half where the drink is not ready (§7.3).
  def with_safety(seconds)
    [ (seconds * config.fetch("eta_safety_factor").to_f).ceil, 0 ].max
  end

  def config
    @config ||= @store.effective_scheduler_config
  end
end
