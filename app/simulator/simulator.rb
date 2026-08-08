# Discrete-event simulation of a shift (DESIGN.md §10.1, §10.2).
#
# **The one rule (§10.1): this runs the production scheduler, not a
# reimplementation of it.** `Scheduler.pick_next` is called here exactly as
# `ClaimNextDrink` calls it, with a simulated clock instead of `Time.current`.
# Otherwise you are tuning a model of your system rather than your system, and
# every conclusion the dashboard draws is about the model.
#
# Event-driven per §10.2: a priority queue over
# `ORDER_ARRIVES · DRINK_STARTED · DRINK_FINISHED · DRINK_FAILED · ORDER_READY ·
# PICKUP`, with the clock jumping between events. An eleven-hour day is a few
# thousand events rather than 40,000 idle ticks.
module Simulator
  # `actual_prep_seconds` is what the drink would take on an average station;
  # `service_seconds` is what it actually occupied one for, after that station's
  # skill and any fatigue. Utilisation must be computed from the latter or it
  # understates how busy the shop was — and §10.4 makes staffing decisions on it.
  Drink = Struct.new(:id, :prep_seconds, :actual_prep_seconds, :service_seconds, :remake,
                     :started_at, :finished_at, :station, keyword_init: true) do
    def remake? = remake
  end

  Order = Struct.new(:id, :arrived_at, :items, :queue_depth_on_arrival, :ready_at,
                     :first_ready_at, :picked_up_at, :promised_at, :reneged, :web,
                     keyword_init: true) do
    def wait_seconds = ready_at && (ready_at - arrived_at)

    # What the *customer* ordered. `items` grows when a drink is remade (§5.2),
    # so counting it would move a remade 2-drink order into §10.4's "3-6" class
    # — and remade orders are slow ones, carrying extra work and §6.4's priority
    # floor, so dropping them out of "1-2" biases the headline number optimistic.
    def ordered_items = items.reject(&:remake?)

    def ordered_size = ordered_items.size

    # Wait minus the work the order itself brought — the classic flow-time
    # decomposition, and the only part a scheduler can act on.
    #
    # The critical path, not the sum: with idle stations a 2-drink order's
    # drinks are made in parallel, so the least time it could possibly take is
    # its slowest drink. Subtracting the sum would report negative queueing.
    #
    # A remade order therefore reads as having queued through its own failure —
    # the wasted attempt is in `wait_seconds` but not in the critical path.
    # Deliberate: the customer did not ask for the drink to be spilled, so from
    # their side that time is indistinguishable from queueing.
    def queue_seconds
      return nil unless wait_seconds

      [ wait_seconds - items.map(&:prep_seconds).max, 0.0 ].max
    end
    def reneged? = reneged

    # ready_at − first_ready_at: how long the earliest drink sat while the rest
    # were made (§10.4).
    def cohesion_spread = ready_at && first_ready_at ? ready_at - first_ready_at : 0.0

    # §9.6's quality timer, per drink: "measures `now - finished_at` until
    # `picked_up_at`". Per *drink* and not per order — a 20-drink order where 19
    # drinks sat eight minutes is nineteen breaches, and counting it as one
    # (which measuring from `first_ready_at` does) hides exactly the failure the
    # cohesion boost exists to prevent.
    #
    # @return [Array<Float>] seconds each finished drink sat on the counter
    def sat_seconds
      return [] unless picked_up_at

      items.filter_map { |drink| drink.finished_at && (picked_up_at - drink.finished_at) }
    end
  end

  # Runs one shift.
  #
  # @param scenario [Simulator::Scenario]
  # @return [Simulator::Metrics]
  def self.run(scenario)
    world = simulate(scenario)
    Metrics.new(orders: world.completed, seconds: world.clock, stations: scenario.stations,
                reneged: world.reneged, remakes: world.remakes)
  end

  # The World itself, for specs that need to assert on internals such as
  # conservation. Production callers want `run`.
  # @return [Simulator::World]
  def self.simulate(scenario)
    World.new(scenario).tap(&:run)
  end

  # Holds the mutable state of one simulated day. A class rather than a pile of
  # locals because the event handlers all need the same half-dozen collections,
  # and threading them through as arguments obscured what each handler does.
  class World
    attr_reader :clock, :completed, :reneged, :remakes, :arrived

    # Time-integral of the number of orders in the shop, for Little's Law
    # (§17). Accumulated at every event because the count only changes at
    # events — between them it is constant, so the integral is exact rather
    # than sampled.
    attr_reader :order_seconds

    QUALITY_LIMIT = 300 # §6.6 default, for the breach metric

    def initialize(scenario)
      @scenario = scenario
      @rng = Rng.new(scenario.seed)
      @clock = 0.0
      @events = EventQueue.new
      @pending = []
      @completed = []
      @reneged = 0
      @arrived = 0
      @order_seconds = 0.0
      @integrated_to = 0.0
      @remakes = 0
      @next_order_id = 0
      skills = @rng.stream(:stations)
      @stations = Array.new(scenario.stations) { |i| { index: i, busy_until: nil, skill: skills.between(0.85, 1.20) } }
      @state = Scheduler::State.new(flows: [], config: scenario.config)

      schedule_arrivals
    end

    def run
      until @events.empty?
        event = @events.pop

        # Integrate before advancing: @pending held this count for the whole
        # interval just ended.
        @order_seconds += @pending.size * (event.at - @integrated_to)
        @integrated_to = event.at
        @clock = event.at

        case event.type
        when :order_arrives  then on_arrival(event.payload)
        when :drink_finished then on_finished(event.payload)
        when :pickup         then on_pickup(event.payload)
        end

        fill_idle_stations
      end
    end

    private

    # Non-homogeneous Poisson by thinning (§10.3): sample at the peak rate, then
    # reject in proportion to how far below peak the hour is. Uniform arrivals
    # keep the shop below saturation all day, where every scheduler looks alike.
    def schedule_arrivals
      peak = @scenario.peak_rate
      return if peak <= 0

      arrivals = @rng.stream(:arrivals)
      t = 0.0
      while t < @scenario.duration_seconds
        t += arrivals.exponential(1.0 / peak)
        break if t >= @scenario.duration_seconds

        @events.push(t, :order_arrives, size: sample_size(arrivals)) if arrivals.chance(@scenario.arrival_rate_at((t / 3600).floor) / peak)
      end
    end

    def sample_size(arrivals)
      choice = arrivals.categorical(@scenario.size_mix)

      choice.is_a?(Range) ? arrivals.between(choice.min, choice.max + 1).floor : choice
    end

    def on_arrival(payload)
      @arrived += 1
      order = build_order(payload[:size])

      # §10.3 reneging: a web customer quoted a long wait leaves rather than
      # ordering. This is what prices slowness in lost revenue instead of
      # abstract seconds (§10.4), and it is why a saturated shop's wait
      # percentiles stop rising — the customers who would have waited longest
      # are the ones who never join.
      if order.web && @rng.stream(:renege, order.id).uniform < renege_probability
        order.reneged = true
        @reneged += 1
        return
      end

      @pending << order
    end

    def build_order(size)
      id = @next_order_id += 1
      weighted = @scenario.menu.to_h { |item| [ item, item[:weight] ] }

      customer = @rng.stream(:order, id)
      items = Array.new(size) { |i| build_drink("#{id}-#{i}", weighted) }
      web = customer.chance(@scenario.web_share)

      Order.new(
        id: id, arrived_at: @clock, items: items, web: web, reneged: false,
        queue_depth_on_arrival: queued_drinks,
        # §10.3 order-ahead, web only (§9.3). Exercises the scheduler's
        # backward-scheduling path, which nothing else in the model reaches.
        promised_at: promise_for(web, customer)
      )
    end

    # Keyed by the drink's own id: what a drink is, and how long it intrinsically
    # takes, are properties of the drink and must not depend on when the
    # scheduler got round to it (§17, common random numbers).
    # A pickup time the shop is open for. Without the bound, a late-evening order
    # could be promised after close, and §6.2's backward scheduling would then
    # correctly never dispatch it — the order would sit in `@pending` forever,
    # counted as neither served nor lost, silently absent from every metric.
    def promise_for(web, customer)
      return nil unless web && customer.chance(@scenario.order_ahead_share)

      promised = @clock + customer.between(1800, 7200)

      promised <= @scenario.duration_seconds ? promised : nil
    end

    def build_drink(id, weighted, remake: false)
      draw = @rng.stream(:drink, id)
      menu_item = draw.categorical(weighted)

      Drink.new(
        id: id, prep_seconds: menu_item[:prep_seconds],
        # Lognormal around the item's mean, so the tail is on the slow side only
        # — a drink never takes negative time (§10.3).
        actual_prep_seconds: draw.lognormal(menu_item[:prep_seconds], @scenario.prep_sigma),
        remake: remake
      )
    end

    # Estimated wait, for the renege decision. The naive estimate of §12 step 3:
    # outstanding work over stations. A customer decides on what they are told,
    # not on what turns out to be true.
    def renege_probability
      eta = queued_seconds / [ @scenario.stations, 1 ].max

      ((eta - 480) / 1200.0).clamp(0.0, 0.8)
    end

    def queued_drinks = @pending.sum { |o| o.items.count { |d| d.started_at.nil? } }
    def queued_seconds = @pending.sum { |o| o.items.reject(&:started_at).sum(&:prep_seconds) }

    # Every idle station takes work until the scheduler has none to give. This
    # is the only place drinks start, so DRINK_STARTED is implicit in it.
    def fill_idle_stations
      loop do
        station = @stations.find { |s| s[:busy_until].nil? }
        break if station.nil?

        rebuild_state
        picked = Scheduler.pick_next(@state, @clock)
        break if picked.nil?

        start_drink(picked, station)
      end
    end

    # Rebuilt from pending orders every cycle, exactly as §6.5 requires in
    # production — no queue table, deficits carried across.
    def rebuild_state
      carried = @state.flows.to_h { |flow| [ flow.id, flow.deficit ] }

      flows = @pending.filter_map do |order|
        queued = order.items.reject(&:started_at)
        next if queued.empty?

        Scheduler::Flow.new(
          id: order.id, arrived_at: order.arrived_at, promised_at: order.promised_at,
          queue: queued.map { |d| Scheduler::Item.new(id: d.id, prep_seconds: d.prep_seconds, enqueued_at: order.arrived_at, remake: d.remake?) },
          made_count: order.items.count(&:finished_at),
          total_items: order.items.size,
          deficit: carried.fetch(order.id, 0)
        )
      end

      @state = Scheduler::State.new(flows: flows, config: @scenario.config,
                                    pointer: @state.pointer, granted_to: @state.granted_to)
    end

    def start_drink(picked, station)
      order = @pending.find { |o| o.id == picked[:flow].id }
      drink = order.items.find { |d| d.id == picked[:item].id }

      # Barista skill is drawn once per station and persists — a fast barista is
      # fast all shift, which makes utilisation uneven in a way averaging hides.
      duration = drink.actual_prep_seconds * station[:skill]
      duration *= 1.08 if queued_drinks > 12 # fatigue (§10.3)

      drink.service_seconds = duration
      drink.started_at = @clock
      drink.station = station[:index]
      station[:busy_until] = @clock + duration

      @events.push(@clock + duration, :drink_finished, order: order, drink: drink, station: station)
    end

    def on_finished(payload)
      order, drink, station = payload.values_at(:order, :drink, :station)
      station[:busy_until] = nil

      # §10.3: 2% of drinks go wrong. The remake is a *new* drink on the same
      # order (§5.2), which is what gives the order a pending remake and
      # therefore §6.4's priority floor — the only path that exercises it.
      if @rng.stream(:quality, drink.id).chance(@scenario.remake_rate)
        @remakes += 1
        order.items << build_drink("#{drink.id}r", @scenario.menu.to_h { |i| [ i, i[:weight] ] }, remake: true)
        drink.finished_at = @clock
        return
      end

      drink.finished_at = @clock
      order.first_ready_at ||= @clock

      return unless order.items.all?(&:finished_at)

      order.ready_at = @clock
      @completed << order
      @pending.delete(order)

      # §10.3 pickup delay: exponential, and "what exercises the quality timer".
      mean = order.web ? 180 : 100
      @events.push(@clock + @rng.stream(:pickup, order.id).exponential(mean), :pickup, order: order)
    end

    def on_pickup(payload)
      payload[:order].picked_up_at = @clock
    end

    public

    # Every dispatched drink, as the lane ribbon needs it (§10.6): which station
    # made it, when, and for which order.
    #
    # A ribbon fed by summary statistics would be a chart of numbers rather than
    # a picture of the schedule — the whole point is seeing a large order's
    # drinks *interleaved* with small ones, which only per-drink placement shows.
    #
    # Where every order's drinks were made, without the per-drink detail — enough
    # to find an order in a day the ribbon only ever shows a slice of (§10.6).
    #
    # Cheap by design: one entry per order rather than per drink, so the client
    # can locate any order without asking the server to re-run the day.
    #
    # @return [Array<Array>] `[order_id, first_start, last_finish, size]`
    def order_spans
      (@completed + @pending).filter_map do |order|
        started = order.items.filter_map(&:started_at)
        next if started.empty?

        finishes = order.items.filter_map(&:finished_at)

        [ order.id, started.min.round(2), (finishes.max || started.max).round(2), order.items.size ]
        # By start time, not id: an order-ahead order (§10.3) is dispatched hours
        # after it arrives, so id order and ribbon order are genuinely different.
      end.sort_by { |span| span[1] }
    end

    # @param window [Range, nil] simulated seconds to include; the full day is
    #   thousands of capsules and no screen renders it legibly
    # @return [Array<Hash>]
    def timeline(window: nil)
      drinks = (@completed + @pending).flat_map { |order| order.items.map { |d| [ order, d ] } }

      drinks.filter_map do |order, drink|
        next if drink.started_at.nil?
        next if window && !window.cover?(drink.started_at)

        { order_id: order.id, drink_id: drink.id, station: drink.station,
          started_at: drink.started_at.round(2), finished_at: drink.finished_at&.round(2),
          prep_seconds: drink.prep_seconds, remake: drink.remake?,
          order_size: order.items.size }
      end.sort_by { |d| [ d[:started_at], d[:station] ] }
    end
  end
end
