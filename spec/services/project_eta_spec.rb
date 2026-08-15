require "rails_helper"

RSpec.describe ProjectEta do
  # Safety factor 1.0 keeps the arithmetic legible; the factor gets its own
  # example rather than being smeared across every other expectation.
  let(:store) do
    create(:store, :with_stations,
           scheduler_config: { "eta_safety_factor" => 1.0, "aging_enabled" => false })
  end
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  def queue(order, count, prep: 60, queued_at: 1.minute.ago)
    count.times.map do |i|
      create(:order_item, order: order, menu_item: menu_item, prep_seconds: prep,
                          queued_at: queued_at, sequence: i + 1)
    end
  end

  describe "the projection itself (§7.1)" do
    it "spreads queued work across the active stations" do
      order = create(:order, store: store)
      queue(order, 3) # 3 drinks, 3 stations, one round of 60s

      expect(described_class.for_open_orders(store)[order.id]).to eq(60)
    end

    # §7.1: "Order ETA = max over its items." An order is ready when its slowest
    # drink is, not when its first one is — that is the whole reason a customer
    # with four drinks waits longer than one with one.
    it "takes the last drink of an order, not the first" do
      order = create(:order, store: store)
      queue(order, 6) # two rounds across three stations

      expect(described_class.for_open_orders(store)[order.id]).to eq(120)
    end

    it "uses active stations rather than the seeded station_count (§4.1)" do
      store.stations.limit(2).update_all(active: false)
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_open_orders(store)[order.id]).to eq(180)
    end

    # A store with every station deactivated still owes an answer, and dividing
    # by zero is not one.
    it "still answers when every station is deactivated" do
      store.stations.update_all(active: false)
      order = create(:order, store: store)
      queue(order, 2)

      expect(described_class.for_open_orders(store)[order.id]).to eq(120)
    end

    it "applies eta_safety_factor (§7.1)" do
      store.update!(scheduler_config: store.scheduler_config.merge("eta_safety_factor" => 1.5))
      order = create(:order, store: store)
      queue(order, 3)

      expect(described_class.for_open_orders(store)[order.id]).to eq(90)
    end

    it "returns nothing when there is nothing queued" do
      expect(described_class.for_open_orders(store)).to be_empty
    end
  end

  # The reason this class replaces NaiveEta. Under DRR a single drink arriving
  # behind a catering order is interleaved almost immediately (§2), and a
  # cumulative-FIFO formula quotes it as though it waits for all fifteen.
  describe "why the formula was replaced (§7.1, ADR-0004)" do
    it "quotes a small order behind a catering order by when it will be made" do
      catering = create(:order, store: store, placed_at: 5.minutes.ago)
      single = create(:order, store: store, placed_at: 1.minute.ago)
      queue(catering, 15, queued_at: 5.minutes.ago)
      queue(single, 1, queued_at: 1.minute.ago)

      estimates = described_class.for_open_orders(store)

      # 15 drinks ahead at 60s over 3 stations is 300s under FIFO. Fair queuing
      # interleaves, so this customer waits closer to one round.
      expect(estimates[single.id]).to be < 180
      expect(estimates[single.id]).to be < estimates[catering.id]
    end

    # The claim §7.1 makes for this method: it tracks scheduler config rather
    # than assuming it. A formula over queue position cannot do this.
    it "moves when the policy moves" do
      catering = create(:order, store: store, placed_at: 5.minutes.ago)
      single = create(:order, store: store, placed_at: 1.minute.ago)
      queue(catering, 15, queued_at: 5.minutes.ago)
      queue(single, 1, queued_at: 1.minute.ago)

      drr = described_class.for_open_orders(store)[single.id]

      store.update!(scheduler_config: store.scheduler_config.merge("policy" => "fifo"))
      fifo = described_class.for_open_orders(store)[single.id]

      expect(fifo).to be > drr
    end
  end

  describe "work already in progress" do
    it "does not free a station that is busy making a drink" do
      busy = create(:order, store: store)
      item = queue(busy, 1).first
      item.update!(status: "in_progress", station_id: store.active_stations.first.id,
                   started_at: Time.current, prep_seconds: 300)

      waiting = create(:order, store: store)
      queue(waiting, 3)

      # Two free stations, not three, so the third drink waits a round.
      expect(described_class.for_open_orders(store)[waiting.id]).to eq(120)
    end

    # The board is the thing customers watch. An order whose every drink is
    # already being made is invisible to the scheduler's flow set (§6.5 builds
    # it from `queued` only), so without seeding it the projection has nothing
    # for that order and the board reads "ready" while a barista is still
    # pouring it.
    it "still estimates an order whose every drink is already being made" do
      order = create(:order, store: store)
      item = queue(order, 1, prep: 120).first
      item.update!(status: "in_progress", station_id: store.active_stations.first.id,
                   started_at: Time.current)

      expect(described_class.for_open_orders(store)[order.id]).to be_within(2).of(120)
    end

    it "counts an in-progress drink toward its order's ETA alongside queued ones" do
      order = create(:order, store: store)
      in_progress, = queue(order, 1, prep: 300)
      in_progress.update!(status: "in_progress", station_id: store.active_stations.first.id,
                          started_at: Time.current)
      queue(order, 1, prep: 60)

      # The 60s drink is quick; the order is not ready until the 300s one is.
      expect(described_class.for_open_orders(store)[order.id]).to be_within(2).of(300)
    end

    # An overrunning drink is nearly done, not overdue by however long it has
    # been. Projecting its station as free in the past would let the projection
    # dispatch before `now`.
    it "frees an overrunning drink's station now rather than in the past" do
      busy = create(:order, store: store)
      item = queue(busy, 1).first
      item.update!(status: "in_progress", station_id: store.active_stations.first.id,
                   started_at: 1.hour.ago, prep_seconds: 60)

      waiting = create(:order, store: store)
      queue(waiting, 3)

      expect(described_class.for_open_orders(store)[waiting.id]).to eq(60)
    end
  end

  # The projection runs `DeficitScheduler.pick_next`, which mutates the state it is
  # given — drawing down deficits, advancing the ring pointer, shifting items
  # off queues (§6.2). Those mutations must stay in the loaded copy. If they
  # ever reached Redis, quoting a customer an ETA would consume the real
  # queue's deficits and reorder what the kitchen makes next.
  describe "isolation from live scheduler state (§6.5)" do
    # Through `BobaGals.redis_key`, not a hand-written pattern — keys are
    # namespaced per environment, and a literal "sched:..." glob matches nothing
    # and makes this whole comparison vacuous.
    def redis_snapshot
      BobaGals::REDIS.with do |redis|
        keys = redis.keys("#{BobaGals.redis_key('sched', store.id)}:*").sort
        keys.to_h { |key| [ key, redis.get(key) ] }
      end
    end

    # The fixture matters. Six 60s drinks against a 120s quantum spend exactly
    # what they are granted, so the deficits round-trip to zero and a projection
    # that *did* persist would write back what was already there — the assertion
    # would hold for the wrong reason. Three orders of 50s drinks leave a real
    # remainder and move the ring pointer off its first flow.
    it "leaves the persisted deficits and ring pointer untouched" do
      3.times do |i|
        order = create(:order, store: store, placed_at: (5 - i).minutes.ago)
        queue(order, 5, prep: 50, queued_at: (5 - i).minutes.ago)
      end
      SchedulerStateStore.new(store).save(SchedulerStateStore.new(store).load)

      before = redis_snapshot
      expect(before).not_to be_empty, "nothing was persisted, so this would pass vacuously"

      described_class.for_open_orders(store)

      expect(redis_snapshot).to eq(before)
    end

    it "does not consume the queue it projects" do
      order = create(:order, store: store)
      queue(order, 4)

      described_class.for_open_orders(store)

      expect(OrderItem.where(status: "queued").count).to eq(4)
    end

    it "is repeatable — projecting twice gives the same answer" do
      order = create(:order, store: store)
      queue(order, 5)

      expect(described_class.for_open_orders(store)).to eq(described_class.for_open_orders(store))
    end
  end

  describe "#per_item" do
    it "yields a start and ready time for every queued drink" do
      order = create(:order, store: store)
      items = queue(order, 3)

      projection = described_class.new(store).per_item

      expect(projection.keys).to match_array(items.map(&:id))
      expect(projection.values).to all(include(:start_at, :ready_at))
    end

    it "starts a drink when a station frees, and finishes it a prep time later" do
      order = create(:order, store: store)
      item = queue(order, 1, prep: 90).first
      now = Time.current

      projection = described_class.new(store, now: now).per_item.fetch(item.id)

      expect(projection[:start_at]).to be_within(1.second).of(now)
      expect(projection[:ready_at]).to be_within(1.second).of(now + 90)
    end
  end

  # Order-ahead orders reach the projection through the scheduler's own
  # backward scheduling (§6.2) rather than through a rule repeated here — which
  # is the point of projecting with `pick_next` instead of a formula.
  describe "order-ahead" do
    it "does not let a far-future promise inflate the wait at the counter" do
      promised = create(:order, store: store, promised_at: 2.hours.from_now)
      queue(promised, 6, queued_at: 1.minute.ago)
      walk_up = create(:order, store: store)
      queue(walk_up, 1)

      expect(described_class.for_open_orders(store)[walk_up.id]).to eq(60)
    end

    # The example above watches the *neighbour*. It passed throughout the
    # window in which an order-ahead customer was quoted zero seconds, because
    # nothing asked what that customer was told.
    #
    # §6.2 schedules a promise backward, so `pick_next` correctly refuses to
    # dispatch it yet — it never reached `@item_projection`, and `for_order`'s
    # `fetch(id, 0)` default answered on its behalf. Someone ordering at 9am for
    # an 11am pickup saw "ready now" (§7.3).
    it "quotes a promised order for when it was promised, not zero" do
      now = Time.current
      promised = create(:order, store: store, promised_at: now + 2.hours)
      queue(promised, 1, queued_at: now - 1.minute)

      expect(described_class.for_order(store, promised, now: now)).to eq(7200)
    end

    it "still answers when every open order is promised for later" do
      now = Time.current
      promised = create(:order, store: store, promised_at: now + 90.minutes)
      queue(promised, 2, queued_at: now - 1.minute)

      expect(described_class.for_open_orders(store, now: now)).to eq(promised.id => 5400)
    end

    # §7.1's safety factor pads an estimate. A promise is the time the customer
    # chose, and padding it scales with the horizon — at 1.15 a two-hour order
    # ahead would be quoted eighteen minutes after the slot it asked for.
    it "does not pad a promised time with the safety factor" do
      store.update!(scheduler_config: store.scheduler_config.merge("eta_safety_factor" => 1.5))
      now = Time.current
      promised = create(:order, store: store, promised_at: now + 1.hour)
      queue(promised, 1, queued_at: now - 1.minute)

      expect(described_class.for_order(store, promised, now: now)).to eq(3600)
    end

    # Once the promise comes within reach, §6.2 releases it and it projects like
    # anything else — the promised time must not pin it open forever.
    it "projects a promise that has come due as ordinary work" do
      now = Time.current
      due = create(:order, store: store, promised_at: now + 30.seconds)
      queue(due, 1, queued_at: now - 1.minute)

      expect(described_class.for_order(store, due, now: now)).to be <= 60
    end
  end

  # §7.3: the seeded base_prep_seconds are guesses, and the projection is only
  # as good as the durations it assumes. "This is the difference between a board
  # customers trust and one they learn to ignore."
  describe "learned prep times (§7.3)" do
    def learn(item, seconds:, samples:)
      create(:prep_time_stat, menu_item: item, ewma_seconds: seconds, sample_count: samples)
    end

    it "projects from the learned duration once there is enough evidence" do
      learn(menu_item, seconds: 120, samples: PrepTimeStat::MINIMUM_SAMPLES)
      order = create(:order, store: store)
      queue(order, 1, prep: 60)

      expect(described_class.for_open_orders(store)[order.id]).to eq(120)
    end

    # An EWMA over three drinks is one unlucky Tuesday. Below the bar the seeded
    # guess still wins, which is what MINIMUM_SAMPLES is for.
    it "keeps using the seeded guess below the evidence bar" do
      learn(menu_item, seconds: 120, samples: PrepTimeStat::MINIMUM_SAMPLES - 1)
      order = create(:order, store: store)
      queue(order, 1, prep: 60)

      expect(described_class.for_open_orders(store)[order.id]).to eq(60)
    end

    it "applies the learned duration to a drink already being made" do
      learn(menu_item, seconds: 200, samples: PrepTimeStat::MINIMUM_SAMPLES)
      order = create(:order, store: store)
      item = queue(order, 1, prep: 60).first
      item.update!(status: "in_progress", station_id: store.active_stations.first.id,
                   started_at: Time.current)

      expect(described_class.for_open_orders(store)[order.id]).to be_within(2).of(200)
    end

    # Keyed per menu item, so learning that Brown Sugar Pearls run long does not
    # slow down the estimate for a Thai Tea.
    it "learns per menu item rather than store-wide" do
      slow = create(:menu_item, store: store, base_prep_seconds: 60)
      learn(slow, seconds: 300, samples: PrepTimeStat::MINIMUM_SAMPLES)

      quick_order = create(:order, store: store)
      create(:order_item, order: quick_order, menu_item: menu_item, prep_seconds: 60,
                          queued_at: 1.minute.ago, sequence: 1)

      expect(described_class.for_open_orders(store)[quick_order.id]).to eq(60)
    end
  end

  # A store with no station rows at all — not merely deactivated ones, which the
  # `presence` fallback already covers. `stations.order(:id).first(1)` is `[]`
  # there, so `free_at` was empty, `each_index.min_by` returned nil and
  # `free_at[nil]` raised TypeError before `pick_next` was ever consulted. That
  # runs inside `CreateOrder`'s transaction, so it 500-ed every order placement
  # for such a store.
  describe "a store with no stations at all" do
    it "still answers, projecting as though one station were about to open" do
      bare = create(:store)
      item = create(:menu_item, store: bare, base_prep_seconds: 60)
      order = create(:order, store: bare)
      create(:order_item, order: order, menu_item: item, prep_seconds: 60)

      expect { described_class.for_open_orders(bare) }.not_to raise_error
      expect(described_class.for_open_orders(bare)[order.id]).to be_positive
    end

    it "does not crash on an empty queue either" do
      expect { described_class.for_open_orders(create(:store)) }.not_to raise_error
    end
  end
end
