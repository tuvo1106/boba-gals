require "rails_helper"

RSpec.describe "finishing and undoing drinks" do
  let(:store) { create(:store) }
  let(:order) { create(:order, store: store, status: "in_progress") }

  def working_drink(**attrs)
    create(:order_item, :in_progress, order: order, **attrs)
  end

  describe FinishDrink do
    it "marks the drink finished and stamps the time" do
      item = working_drink

      result = described_class.new.call(item)

      expect(result).to be_success
      expect(item.reload).to have_attributes(status: "finished")
      expect(item.finished_at).to be_present
    end

    it "refuses a drink that was never started" do
      item = create(:order_item, order: order)

      expect(described_class.new.call(item)).not_to be_success
    end

    it "records the observed duration on the event" do
      item = working_drink(started_at: 90.seconds.ago)

      described_class.new.call(item)

      event = SchedulerEvent.find_by(event_type: "item_finished", order_item: item)
      expect(event.payload["observed_seconds"]).to be_within(2).of(90)
    end

    # §7.3 learns from `finished_at - started_at`, and this is the only moment
    # that observation exists. Without a guard here the EWMA could be silently
    # disconnected and every prep-time spec would still pass, because they all
    # drive `RecordPrepTime` directly.
    describe "feeding the EWMA (§7.3)" do
      include ActiveJob::TestHelper

      it "learns the drink's duration once the undo window has closed" do
        item = working_drink(started_at: 90.seconds.ago)

        described_class.new.call(item)

        expect(PrepTimeStat.count).to eq(0), "learning inside the undo window reopens #69"

        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(PrepTimeStat.find_by(menu_item_id: item.menu_item_id).ewma_seconds)
          .to be_within(2).of(90)
      end

      it "schedules the sample for a full undo window later (§5.2)" do
        item = working_drink

        expect { described_class.new.call(item) }
          .to have_enqueued_job(RecordPrepTimeJob)
          .at(a_value_within(2.seconds).of(UndoLastAction::WINDOW.from_now))
      end

      # A data problem must never fail the transition the barista did make.
      it "still finishes the drink when the observation is rejected as an outlier" do
        item = working_drink(started_at: 40.minutes.ago)
        create(:prep_time_stat, menu_item_id: item.menu_item_id, ewma_seconds: 60,
                                sample_count: PrepTimeStat::MINIMUM_SAMPLES)

        expect(described_class.new.call(item)).to be_success

        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(item.reload.status).to eq("finished")
        expect(PrepTimeStat.find_by(menu_item_id: item.menu_item_id).ewma_seconds).to eq(60)
      end
    end

    # §9.6, #80 learns from `ready_at - first_ready_at`, and the order reaching
    # `ready` is the only moment that observation exists. Same deferred-by-
    # undo-window reasoning as the prep-time EWMA above (ADR-0019).
    describe "feeding the quality-spread EWMA (§9.6, #80)" do
      include ActiveJob::TestHelper

      it "learns the order's spread once the undo window has closed" do
        first = working_drink
        second = working_drink

        described_class.new.call(first)
        described_class.new.call(second)

        expect(QualitySpreadStat.count).to eq(0), "learning inside the undo window reopens #69's failure mode"

        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(QualitySpreadStat.find_by(store: store, size_class: "1-2").sample_count).to eq(1)
      end

      it "schedules the sample for a full undo window later, only once the order is ready" do
        first = working_drink
        second = working_drink

        expect { described_class.new.call(first) }.not_to have_enqueued_job(RecordQualitySpreadJob)

        expect { described_class.new.call(second) }
          .to have_enqueued_job(RecordQualitySpreadJob)
          .at(a_value_within(2.seconds).of(UndoLastAction::WINDOW.from_now))
      end
    end

    describe "order rollup (§5.1)" do
      it "moves a part-finished order to partially_ready" do
        working_drink
        second = working_drink
        described_class.new.call(second)

        expect(order.reload.status).to eq("partially_ready")
      end

      it "moves the order to ready once every drink is done" do
        first = working_drink
        second = working_drink

        described_class.new.call(first)
        described_class.new.call(second)

        expect(order.reload).to have_attributes(status: "ready")
        expect(order.ready_at).to be_present
      end

      # first_ready_at anchors the quality timer and the cohesion spread
      # metric — how long the earliest drink sat while the rest were made
      # (§9.6, §10.4).
      it "stamps first_ready_at on the first finished drink and never moves it" do
        first = working_drink
        second = working_drink

        described_class.new.call(first)
        original = order.reload.first_ready_at

        travel_to(2.minutes.from_now) { described_class.new.call(second) }

        expect(order.reload.first_ready_at).to eq(original)
      end

      it "records an order_ready event when the last drink lands" do
        item = working_drink

        expect { described_class.new.call(item) }
          .to change { SchedulerEvent.where(event_type: "order_ready").count }.by(1)
      end
    end
  end

  describe UndoLastAction do
    # Undo corrects a mistap, not a drink (§5.2). A drink genuinely made and
    # wrong is a remake, which shipped at build step 8 — see `FailDrink`.
    it "returns a finished drink to in_progress inside the window" do
      item = working_drink
      FinishDrink.new.call(item)

      result = described_class.new.call(item.reload)

      expect(result).to be_success
      expect(item.reload).to have_attributes(status: "in_progress", finished_at: nil)
    end

    it "returns an in-progress drink to queued and releases the station" do
      item = working_drink

      described_class.new.call(item)

      expect(item.reload).to have_attributes(
        status: "queued", station_id: nil, barista_id: nil, started_at: nil
      )
    end

    it "refuses once the 60-second window has passed" do
      item = working_drink
      FinishDrink.new.call(item)

      result = travel_to(61.seconds.from_now) { described_class.new.call(item.reload) }

      expect(result).not_to be_success
      expect(result.error).to match(/window has passed/)
    end

    it "refuses a queued drink, which has nothing to undo" do
      expect(described_class.new.call(create(:order_item, order: order))).not_to be_success
    end

    # An undone finish must move the order back out of ready, or the board keeps
    # telling a customer their drink is waiting for them (§5.2).
    it "moves the order back from ready to partially_ready" do
      first = working_drink
      second = working_drink
      FinishDrink.new.call(first)
      FinishDrink.new.call(second)
      expect(order.reload.status).to eq("ready")

      described_class.new.call(second.reload)

      expect(order.reload).to have_attributes(status: "partially_ready", ready_at: nil)
    end

    # Issue #69. A mistap is almost always *early* — the wrong card, or a tap
    # before the drink is done — so a phantom duration biases the EWMA down,
    # the projection quotes short, and the board goes late (§7.3). The [0.25x,
    # 4x] outlier guard does not catch it, because a mistap is plausible.
    #
    # These assert on `PrepTimeStat` rather than on the job, so they stay true
    # if the mechanism from ADR-0019 is ever replaced by a different one.
    describe "discarding the prep-time sample (§5.2, §7.3)" do
      include ActiveJob::TestHelper

      def ewma_for(item)
        PrepTimeStat.find_by(menu_item_id: item.menu_item_id)&.ewma_seconds
      end

      it "learns nothing from a finish that was undone" do
        item = working_drink(started_at: 90.seconds.ago)
        FinishDrink.new.call(item)

        described_class.new.call(item.reload)
        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(ewma_for(item)).to be_nil
      end

      # The value has to be untouched, not merely present: an undo that left a
      # phantom sample behind would still pass a `PrepTimeStat.count` check
      # whenever the menu item already had a stat row.
      it "leaves an existing average exactly where it was" do
        item = working_drink(started_at: 20.seconds.ago)
        create(:prep_time_stat, menu_item_id: item.menu_item_id, ewma_seconds: 60,
                                sample_count: PrepTimeStat::MINIMUM_SAMPLES)
        FinishDrink.new.call(item)

        described_class.new.call(item.reload)
        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(ewma_for(item)).to eq(60)
        expect(PrepTimeStat.find_by(menu_item_id: item.menu_item_id).sample_count)
          .to eq(PrepTimeStat::MINIMUM_SAMPLES)
      end

      # Both finishes enqueue a job, and only the second one happened. Without
      # the elapsed-window check in `RecordPrepTimeJob` the drink would be
      # counted twice, which is the same bias in the other direction.
      it "learns exactly one sample across an undo and a re-finish" do
        item = working_drink(started_at: 90.seconds.ago)
        FinishDrink.new.call(item)
        described_class.new.call(item.reload)
        travel_to(10.seconds.from_now) { FinishDrink.new.call(item.reload) }

        travel_to(UndoLastAction::WINDOW.from_now + 30.seconds) { perform_enqueued_jobs }

        expect(PrepTimeStat.find_by(menu_item_id: item.menu_item_id).sample_count).to eq(1)
      end

      # The window is the *only* thing gating the sample, so a finish nobody
      # touched must still teach the board (§7.3) — a fix that discarded
      # everything would pass every example above.
      it "still learns from a finish that stands" do
        item = working_drink(started_at: 90.seconds.ago)
        FinishDrink.new.call(item)

        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(ewma_for(item)).to be_within(2).of(90)
      end
    end

    # Same idiom as the prep-time discarding block above, for the order-level
    # spread learned at ready instead of the item-level duration learned at
    # finish (§9.6, #80).
    describe "discarding the quality-spread sample (§5.2, §9.6, #80)" do
      include ActiveJob::TestHelper

      def spread_stat
        QualitySpreadStat.find_by(store: store, size_class: "1-2")
      end

      it "learns nothing from a ready transition that was undone" do
        first = working_drink
        second = working_drink
        FinishDrink.new.call(first)
        FinishDrink.new.call(second)

        described_class.new.call(second.reload)
        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(spread_stat).to be_nil
      end

      it "leaves an existing average exactly where it was" do
        create(:quality_spread_stat, :confident, store: store, size_class: "1-2", ewma_seconds: 900)
        first = working_drink
        second = working_drink
        FinishDrink.new.call(first)
        FinishDrink.new.call(second)

        described_class.new.call(second.reload)
        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(spread_stat.ewma_seconds).to eq(900)
        expect(spread_stat.sample_count).to eq(QualitySpreadStat::MINIMUM_SAMPLES)
      end

      it "learns exactly one sample across an undo and a re-finish" do
        first = working_drink
        second = working_drink
        FinishDrink.new.call(first)
        FinishDrink.new.call(second)
        described_class.new.call(second.reload)
        travel_to(10.seconds.from_now) { FinishDrink.new.call(second.reload) }

        travel_to(UndoLastAction::WINDOW.from_now + 30.seconds) { perform_enqueued_jobs }

        expect(spread_stat.sample_count).to eq(1)
      end

      it "still learns from a ready transition that stands" do
        first = working_drink
        second = working_drink
        FinishDrink.new.call(first)
        FinishDrink.new.call(second)

        travel_to(UndoLastAction::WINDOW.from_now + 1.second) { perform_enqueued_jobs }

        expect(spread_stat.sample_count).to eq(1)
      end
    end
  end

  # §15's histograms are observed at the same one event the order_ready
  # SchedulerEvent and the SMS already key off — see the comments there for
  # why that event fires exactly once per genuine ready transition.
  describe "wait metrics (§15)" do
    it "records the order's wait time, tagged by size class" do
      item = working_drink
      order.update!(placed_at: 5.minutes.ago)

      expect(Yabeda.boba_gals.order_wait_seconds).to receive(:measure)
        .with({ store: store.id, size_class: "1-2" }, a_value_within(2).of(300))

      FinishDrink.new.call(item)
    end

    it "records the signed ETA error against quoted_wait_seconds" do
      item = working_drink
      order.update!(placed_at: 5.minutes.ago, quoted_wait_seconds: 200)

      expect(Yabeda.boba_gals.eta_signed_error_seconds).to receive(:measure)
        .with({ store: store.id }, a_value_within(2).of(100))

      FinishDrink.new.call(item)
    end

    it "does not record anything while the order is only part made" do
      first = working_drink
      working_drink

      expect(Yabeda.boba_gals.order_wait_seconds).not_to receive(:measure)

      FinishDrink.new.call(first)
    end

    it "skips the ETA error when quoted_wait_seconds was never set" do
      item = working_drink
      order.update!(quoted_wait_seconds: nil)

      expect(Yabeda.boba_gals.eta_signed_error_seconds).not_to receive(:measure)

      FinishDrink.new.call(item)
    end
  end

  # §9.7: exactly one message, when the order transitions to ready.
  describe "the ready SMS (§9.7)" do
    # `perform_enqueued_jobs` — the undo/re-finish example needs the job to
    # actually run, because the whole question is what happens on the second
    # enqueue.
    include ActiveJob::TestHelper

    let(:phone) { "+15555550123" } # seeded demo value, never a real number
    let(:sender) { instance_double(LogSender) }

    before do
      allow(NotificationSender).to receive(:current).and_return(sender)
      allow(sender).to receive(:deliver).and_return(NotificationSender::Result.new(success?: true))
    end

    def web_order_with_one_drink
      web = create(:order, :web, store: store, status: "in_progress", customer_phone: phone)
      [ web, create(:order_item, :in_progress, order: web, sequence: 1) ]
    end

    it "enqueues one message when the last drink is finished" do
      _web, item = web_order_with_one_drink

      expect { FinishDrink.new.call(item) }.to have_enqueued_job(SendReadySmsJob)
    end

    it "does not enqueue while the order is only part made" do
      web = create(:order, :web, store: store, status: "in_progress", customer_phone: phone)
      first = create(:order_item, :in_progress, order: web, sequence: 1)
      create(:order_item, order: web, sequence: 2)

      expect { FinishDrink.new.call(first) }.not_to have_enqueued_job(SendReadySmsJob)
    end

    # This is why `ready_at` cannot be the guard and a column can. Undo moves the
    # order back out of ready (§5.2) and re-finishing re-enters it, so the job is
    # enqueued twice — and exactly one message goes out.
    it "sends exactly one message across an undo and a re-finish" do
      web, item = web_order_with_one_drink

      perform_enqueued_jobs do
        FinishDrink.new.call(item)
        UndoLastAction.new.call(item.reload)
        FinishDrink.new.call(item.reload)
      end

      expect(web.reload.status).to eq("ready")
      expect(SchedulerEvent.where(event_type: "order_ready").count).to eq(2)
      expect(sender).to have_received(:deliver).once
    end
  end
end
