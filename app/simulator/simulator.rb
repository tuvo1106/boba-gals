# Discrete-event simulation of a shift (DESIGN.md §10.1, §10.2).
#
# **The one rule (§10.1): this runs the production scheduler, not a
# reimplementation of it.** `Scheduler.pick_next` is called here exactly as
# `ClaimNextDrink` calls it, with a simulated clock instead of `Time.current`.
# Otherwise you are tuning a model of your system rather than your system, and
# every conclusion the dashboard draws is about the model.
#
# Not tick-based. The clock jumps to the next event, so a 12-hour day completes
# in well under a second — which is what makes parameter sweeps of thousands of
# runs practical instead of eyeballing three configurations (§10.2).
module Simulator
  # A drink. Mirrors what the real `OrderItem` carries into the scheduler, plus
  # the actual prep time this run sampled for it.
  # `actual_prep_seconds` is what the drink would take on an average station;
  # `service_seconds` is what it actually occupied one for, after that station's
  # skill and any fatigue. Utilisation must be computed from the latter or it
  # understates how busy the shop was — and §10.4 makes staffing decisions on it.
  Drink = Struct.new(:id, :prep_seconds, :actual_prep_seconds, :service_seconds, :remake,
                     :started_at, :finished_at, keyword_init: true) do
    def remake? = remake
  end

  # An order, and the timestamps the metrics are computed from.
  Order = Struct.new(:id, :arrived_at, :items, :queue_depth_on_arrival, :ready_at, :first_ready_at,
                     keyword_init: true) do
    def wait_seconds = ready_at && (ready_at - arrived_at)

    # ready_at − first_ready_at: how long the earliest drink sat while the rest
    # were made (§10.4).
    def cohesion_spread = ready_at && first_ready_at ? ready_at - first_ready_at : 0.0
  end

  # Runs one shift.
  #
  # @param scenario [Simulator::Scenario]
  # @return [Simulator::Metrics]
  def self.run(scenario)
    rng = Rng.new(scenario.seed)
    clock = 0.0

    pending = []          # orders that have arrived and still have drinks queued
    completed = []
    stations = Array.new(scenario.stations) { { free_at: 0.0, skill: rng.between(0.85, 1.20) } }
    arrivals = generate_arrivals(scenario, rng)
    next_order_id = 0

    # Deficits and the ring pointer live here rather than in Redis (§6.5); the
    # scheduler cannot tell the difference, which is the point.
    state = Scheduler::State.new(flows: [], config: scenario.config)

    until arrivals.empty? && pending.empty?
      station = stations.min_by { |s| s[:free_at] }

      # Jump the clock: either to the next free station, or forward to the next
      # arrival if the shop has run dry.
      clock = [ clock, station[:free_at] ].max
      clock = [ clock, arrivals.first[:at] ].max if pending.empty? && arrivals.any?

      while arrivals.any? && arrivals.first[:at] <= clock
        arrival = arrivals.shift
        order = build_order(arrival, next_order_id += 1, pending, rng, scenario)
        pending << order
      end

      break if pending.empty?

      state = rebuild_state(state, pending, scenario)
      picked = Scheduler.pick_next(state, clock)

      # Nothing dispatchable yet — every pending order is order-ahead and not
      # due. Advance to the next arrival rather than spinning.
      if picked.nil?
        break if arrivals.empty?

        clock = arrivals.first[:at]
        next
      end

      dispatch(picked, station, clock, pending, completed, rng, scenario)
    end

    Metrics.new(orders: completed, seconds: clock, stations: scenario.stations)
  end

  # Non-homogeneous Poisson by thinning (§10.3): sample at the peak rate, then
  # reject in proportion to how far below peak the current hour is. Uniform
  # arrivals would keep the shop below saturation all day, where every scheduler
  # looks the same.
  def self.generate_arrivals(scenario, rng)
    arrivals = []
    t = 0.0
    peak = scenario.peak_rate

    return arrivals if peak <= 0

    while t < scenario.duration_seconds
      t += rng.exponential(1.0 / peak)
      break if t >= scenario.duration_seconds

      hour = (t / 3600).floor
      arrivals << { at: t, size: sample_size(scenario, rng) } if rng.chance(scenario.arrival_rate_at(hour) / peak)
    end

    arrivals
  end

  def self.sample_size(scenario, rng)
    choice = rng.categorical(scenario.size_mix)

    choice.is_a?(Range) ? rng.between(choice.min, choice.max + 1).floor : choice
  end

  def self.build_order(arrival, id, pending, rng, scenario)
    weighted = scenario.menu.to_h { |item| [ item, item[:weight] ] }

    items = Array.new(arrival[:size]) do |i|
      menu_item = rng.categorical(weighted)

      Drink.new(
        id: "#{id}-#{i}",
        prep_seconds: menu_item[:prep_seconds],
        # Lognormal around the item's mean, so the tail is on the slow side
        # only — a drink never takes negative time (§10.3).
        actual_prep_seconds: rng.lognormal(menu_item[:prep_seconds], scenario.prep_sigma),
        remake: false
      )
    end

    Order.new(id: id, arrived_at: arrival[:at], items: items,
              queue_depth_on_arrival: pending.sum { |o| o.items.count { |d| d.started_at.nil? } })
  end

  # Rebuilt from the pending orders every cycle, exactly as §6.5 requires in
  # production — no queue table, deficits carried across.
  def self.rebuild_state(state, pending, scenario)
    carried = state.flows.to_h { |flow| [ flow.id, flow.deficit ] }

    flows = pending.filter_map do |order|
      queued = order.items.reject(&:started_at)
      next if queued.empty?

      Scheduler::Flow.new(
        id: order.id,
        arrived_at: order.arrived_at,
        queue: queued.map { |d| Scheduler::Item.new(id: d.id, prep_seconds: d.prep_seconds, enqueued_at: order.arrived_at, remake: d.remake?) },
        made_count: order.items.count(&:finished_at),
        total_items: order.items.size,
        deficit: carried.fetch(order.id, 0)
      )
    end

    Scheduler::State.new(flows: flows, config: scenario.config,
                         pointer: state.pointer, granted_to: state.granted_to)
  end

  def self.dispatch(picked, station, clock, pending, completed, rng, scenario)
    order = pending.find { |o| o.id == picked[:flow].id }
    drink = order.items.find { |d| d.id == picked[:item].id }

    # Barista skill is drawn once per station and persists — a fast barista is
    # fast all shift, which is what makes station utilisation uneven in a way
    # averaging would hide (§10.3).
    duration = drink.actual_prep_seconds * station[:skill]
    duration *= 1.08 if pending.sum { |o| o.items.count { |d| d.started_at.nil? } } > 12  # fatigue

    drink.service_seconds = duration
    drink.started_at = clock
    drink.finished_at = clock + duration
    station[:free_at] = drink.finished_at

    order.first_ready_at ||= drink.finished_at

    if order.items.all?(&:finished_at)
      order.ready_at = order.items.map(&:finished_at).max
      completed << order
      pending.delete(order)
    end
  end

  private_class_method :generate_arrivals, :sample_size, :build_order, :rebuild_state, :dispatch
end
