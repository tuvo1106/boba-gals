# A drink went wrong: mark it failed and queue a replacement (§5.2, §9.4).
#
# **`finished` is terminal and this never touches it.** A failed drink is not
# un-finished — the remake is a *new* `OrderItem` row with `remake_of` pointing
# back. That is what keeps prep-time statistics honest (§7.3 learns only from
# drinks that were actually made) and what makes remakes visible in reporting.
#
# Not the undo (§5.2). Undo corrects a *mistap* within 60 seconds and rewinds
# the same row; this records that a real drink was really made wrong. Choosing
# undo here would silently delete the evidence and the prep-time sample.
#
# The remake carries §6.4's priority floor by virtue of existing: the scheduler
# sorts a flow with a pending remake into the top tier regardless of age, so the
# customer whose drink was dropped is served ahead of same-age ordinary work
# without anything here having to say so.
class FailDrink
  Result = Struct.new(:success?, :item, :remake, :error, keyword_init: true)

  # §9.4: "Fail/remake requires a reason tap (spill, wrong order, quality)".
  # An allowlist rather than free text — this reaches `scheduler_events`, which
  # is queried, and a typed reason is the difference between a countable metric
  # and a pile of prose.
  REASONS = %w[spill wrong_order quality].freeze

  # @param item [OrderItem] the drink that went wrong
  # @param reason [String] one of {REASONS}
  # @return [FailDrink::Result]
  def call(item, reason:)
    return failure("reason must be one of: #{REASONS.join(', ')}") unless REASONS.include?(reason.to_s)

    # Only a drink being made can fail. A queued drink has not been touched, so
    # there is nothing to remake; a finished one is terminal (§5.2) and would
    # need a handoff surface §9.4 does not have.
    return failure("only a drink in progress can be failed") unless item.status == "in_progress"

    remake = nil

    OrderItem.transaction do
      item.update!(status: "failed", remake_reason: reason)
      remake = create_remake(item, reason)
    end

    SchedulerEvent.record!(
      store: item.order.store,
      event_type: "item_remade",
      order_item: remake,
      payload: { failed_item_id: item.id, reason: reason, station_id: item.station_id,
                 barista_id: item.barista_id }
    )

    # Deliberately no `RecordPrepTime`: this drink was never made, so
    # `finished_at - started_at` measures how long it took to go wrong. §7.3
    # learning from that would teach the board that spills are how long drinks
    # take.

    order = RollUpOrderStatus.new.call(item.order)

    # Outside the transaction (§8). The remake has to reach the kitchen queue
    # and the customer's screen without anyone refreshing.
    BroadcastStoreViews.call(order.store)

    Result.new(success?: true, item: item, remake: remake)
  end

  private

  # The replacement is a copy of what the customer ordered, not of what the
  # barista was making: same menu item, same options, same frozen label and prep
  # time (§4.1). Editing the menu since must not change the drink being remade.
  def create_remake(item, reason)
    item.order.order_items.create!(
      menu_item: item.menu_item,
      selected_options: item.selected_options,
      label: item.label,
      prep_seconds: item.prep_seconds,
      status: "queued",
      queued_at: Time.current,
      # After every existing drink in the order. `sequence` is what the KDS
      # renders as "2 of 5", so a remake appends rather than displacing the
      # position of a drink already in a barista's hand.
      sequence: (item.order.order_items.maximum(:sequence) || 0) + 1,
      remake_of: item,
      remake_reason: reason
    )
  end

  def failure(message)
    Result.new(success?: false, error: message)
  end
end
