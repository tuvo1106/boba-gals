# Rebuilds Scheduler::State from Postgres and Redis, and writes back what
# survives between dispatch cycles (DESIGN.md §6.5).
#
# There is no queue table. The flow set is rebuilt from
# `order_items WHERE status = 'queued'` on every cycle, because at boba-shop
# volume it fits in memory and a materialized queue is a second source of truth
# that can disagree with the first.
#
# Only two things persist: each open order's `deficit`, and the ring pointer.
# Both are safe to lose — a cold Redis costs one round of unfairness, not
# correctness — which is why they live in a store with no persistence (§14.2).
class SchedulerStateStore
  # §6.5. Long enough to outlive any realistic shift, short enough that a
  # finished order's key does not linger for a week.
  DEFICIT_TTL = 6.hours

  def initialize(store)
    @store = store
  end

  # @return [Scheduler::State]
  def load
    flows = build_flows
    deficits = read_deficits(flows.map(&:id))

    flows.each { |flow| flow.deficit = deficits.fetch(flow.id, 0) }

    Scheduler::State.new(
      flows: flows,
      config: Scheduler::Config.from_store(@store.effective_scheduler_config),
      pointer: resume_pointer(flows),
      granted_to: read_granted_to
    )
  end

  # @param state [Scheduler::State]
  # @return [void]
  def save(state)
    BobaGals::REDIS.with do |redis|
      redis.pipelined do |pipe|
        state.flows.each do |flow|
          pipe.set(deficit_key(flow.id), flow.deficit, ex: DEFICIT_TTL.to_i)
        end

        # Stored as the order id it points at, never an array index — an index
        # is meaningless once the flow set is rebuilt from a different queue.
        current = state.flows[state.pointer]
        pipe.set(pointer_key, current.id, ex: DEFICIT_TTL.to_i) if current

        # Round state, and the reason it has to persist: every claim builds a
        # fresh State, so without this the flow under the pointer is granted a
        # quantum on *every* call, can always afford its head, and never yields
        # the ring. That is the same monopolisation §6.2's loop had, reappearing
        # at the call boundary.
        if state.granted_to
          pipe.set(granted_key, state.granted_to, ex: DEFICIT_TTL.to_i)
        else
          pipe.del(granted_key)
        end
      end
    end
  end

  private

  # Ordered by arrival, which is what makes the ring's tie-break stable across
  # rebuilds (§6.5).
  def build_flows
    items = OrderItem.where(status: "queued")
                     .joins(:order)
                     .where(orders: { store_id: @store.id })
                     .merge(Order.open)
                     .order(:queued_at, :id)
                     .includes(:order)

    items.group_by(&:order).sort_by { |order, _| [ order.placed_at, order.id ] }.map do |order, queued|
      Scheduler::Flow.new(
        id: order.id,
        arrived_at: order.placed_at,
        queue: queued.map { |item| build_item(item) },
        # Counted from the order, not from the queue: cohesion asks how much of
        # the order is *done*, and finished drinks have left the queue (§6.4).
        made_count: order.order_items.count { |i| i.status == "finished" },
        total_items: order.order_items.count { |i| i.status != "cancelled" },
        promised_at: order.promised_at,
        first_ready_at: order.first_ready_at
      )
    end
  end

  def build_item(item)
    Scheduler::Item.new(
      id: item.id,
      prep_seconds: item.prep_seconds,
      enqueued_at: item.queued_at,
      remake: item.remake?
    )
  end

  def read_deficits(order_ids)
    return {} if order_ids.empty?

    values = BobaGals::REDIS.with do |redis|
      redis.mget(*order_ids.map { |id| deficit_key(id) })
    end

    order_ids.zip(values).filter_map { |id, raw| [ id, raw.to_f ] if raw }.to_h
  end

  # §6.5: resume at the stored order's position, falling back to 0 when that
  # order is gone. A lost pointer is as harmless as a lost deficit.
  def resume_pointer(flows)
    stored = BobaGals::REDIS.with { |redis| redis.get(pointer_key) }
    return 0 if stored.nil?

    flows.index { |flow| flow.id == stored.to_i } || 0
  end

  def read_granted_to
    raw = BobaGals::REDIS.with { |redis| redis.get(granted_key) }
    raw&.to_i
  end

  def granted_key
    BobaGals.redis_key("sched", @store.id, "granted")
  end

  def deficit_key(order_id)
    BobaGals.redis_key("sched", @store.id, "deficit", order_id)
  end

  def pointer_key
    BobaGals.redis_key("sched", @store.id, "pointer")
  end
end
