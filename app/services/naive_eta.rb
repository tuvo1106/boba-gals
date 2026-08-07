# Placeholder wait estimate: outstanding prep work divided by active stations.
#
# This is the build step 3 estimate, and it is deliberately crude. §7.1 replaces
# it with a forward projection that runs the real scheduler against the current
# queue, because a formula like this drifts the moment the quantum changes — it
# has no idea that fair queuing reorders work.
#
# Two readings of §12's `total_work / stations` are possible, and they differ:
# the flat store-wide one gives every order the same number, which is useless on
# a board. This class uses the cumulative-FIFO reading — an order's estimate is
# all the work ahead of its last drink, plus its own — because that is the only
# reading that distinguishes the next order from the tenth. See ADR-0004.
class NaiveEta
  # @param store [Store]
  # @param now [Time] injected so the estimate a spec asserts is the estimate it set up
  def initialize(store, now: Time.current)
    @store = store
    @now = now
  end

  # @param store [Store]
  # @return [Integer] estimated seconds until a newly placed order is ready
  def self.for_store(store, now: Time.current)
    new(store, now: now).for_new_order
  end

  # @param store [Store]
  # @return [Hash{Integer => Integer}] order id => estimated seconds until ready
  def self.for_open_orders(store, now: Time.current)
    new(store, now: now).for_open_orders
  end

  # The quote shown at ordering time, which §10.4 later measures ETA error and
  # bias against — so it has to be computed the same way the board is.
  # @return [Integer] seconds
  def for_new_order
    with_safety(undeferred_items.sum(&:prep_seconds).to_f / capacity)
  end

  # Per-order estimates for everything currently on the board (§9.5).
  #
  # One pass over the store's active drinks in FIFO order, accumulating work.
  # Every order's estimate is the running total at its *last* drink, which is
  # the same "max over its items" rule §7.1 keeps.
  #
  # @return [Hash{Integer => Integer}] order id => estimated seconds until ready
  def for_open_orders
    estimates = {}
    cumulative = 0

    undeferred_items.each do |item|
      cumulative += item.prep_seconds
      estimates[item.order_id] = with_safety(cumulative.to_f / capacity)
    end

    deferred_orders.each do |order|
      # Their estimate is their promise. Anything derived from queue position
      # would be a smaller number than the time they were told to come back.
      estimates[order.id] = [ (order.promised_at - @now).ceil, 0 ].max
    end

    estimates
  end

  private

  # Runtime capacity is active stations, never the `station_count` seed column
  # (§4.1). Floored at 1: a store with every station deactivated still owes an
  # answer, and dividing by zero is not one.
  def capacity
    @capacity ||= [ @store.active_stations.count, 1 ].max
  end

  def items
    @items ||= OrderItem.active
                        .joins(:order)
                        .where(orders: { store_id: @store.id })
                        .merge(Order.open)
                        .includes(:order)
                        .order(:queued_at, :id)
                        .to_a
  end

  # An order-ahead order that has not reached its backward-scheduled start is
  # not work the store is doing yet, so it must not inflate the wait for
  # everyone standing at the counter.
  def undeferred_items
    @undeferred_items ||= items.reject { |item| deferred_ids.include?(item.order_id) }
  end

  # Naive backward scheduling (§6.2): an order promised further out than its own
  # work plus the promise buffer has not started mattering yet. Step 5 replaces
  # this with the scheduler's `eligible?`, which reasons about the whole queue
  # rather than one order in isolation.
  def deferred_orders
    @deferred_orders ||= begin
      buffer = config.fetch("promise_buffer").to_i
      own_work = items.group_by(&:order_id).transform_values { |group| group.sum(&:prep_seconds) }

      items.map(&:order).uniq.select do |order|
        order.promised? && (order.promised_at - @now) > (own_work.fetch(order.id, 0).to_f / capacity) + buffer
      end
    end
  end

  def deferred_ids
    @deferred_ids ||= deferred_orders.map(&:id).to_set
  end

  def config
    @config ||= @store.effective_scheduler_config
  end

  # §7.1: order ETA is multiplied by `eta_safety_factor`. Quoting the raw
  # estimate means being late half the time, and a customer only notices the
  # half where the drink is not ready.
  def with_safety(seconds)
    (seconds * config.fetch("eta_safety_factor").to_f).ceil
  end
end
