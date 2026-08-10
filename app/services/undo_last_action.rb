# The KDS escape hatch (§9.4): one tap to start, one to finish, no confirmation
# dialogs — and a 60-second undo on the last action.
#
# Undo corrects a *mistap*, not a drink (§5.2). A drink that was genuinely made
# and is wrong is a remake. That distinction is why the window is short and why
# undo is the only thing permitted to move an item backwards out of `finished`.
class UndoLastAction
  WINDOW = 60.seconds

  Result = Struct.new(:success?, :item, :error, keyword_init: true)

  # @param item [OrderItem]
  # @return [UndoLastAction::Result]
  def call(item)
    case item.status
    when "finished"    then revert(item, to: "in_progress", stamped: :finished_at)
    when "in_progress" then revert(item, to: "queued", stamped: :started_at)
    else failure("nothing to undo")
    end
  end

  private

  def revert(item, to:, stamped:)
    at = item.public_send(stamped)
    return failure("undo window has passed") if at.nil? || at < WINDOW.ago

    attrs = { status: to, stamped => nil }

    # Returning to `queued` releases the station and barista too — the drink is
    # genuinely unclaimed again, and leaving it assigned would make the KDS show
    # work nobody is doing.
    attrs.merge!(station: nil, barista: nil, started_at: nil) if to == "queued"

    item.update!(attrs)

    # An undone finish can move an order from `ready` back to `partially_ready`,
    # which is exactly why status is always derived rather than set (§5.2).
    order = RollUpOrderStatus.new.call(item.order)

    # **The prep-time sample is not discarded here, and §5.2 says it must be
    # (issue #69).** `FinishDrink` records one, so undoing a mistap leaves the
    # phantom duration in the EWMA — and mistaps skew early, so they bias the
    # learned time down and the board quotes short (§7.3).
    #
    # This comment used to say the sample did not exist yet because the EWMA
    # arrived at build step 7. It did arrive, and nothing came back here. Left
    # as a known gap rather than patched, because an EWMA cannot be cleanly
    # inverted and the fix is a decision about *when* learning happens.
    BroadcastStoreViews.call(order.store)

    Result.new(success?: true, item: item)
  end

  def failure(message)
    Result.new(success?: false, error: message)
  end
end
