# §9.7: "Exactly one message, sent when the order transitions to `ready`."
#
# `ready` is reachable more than once. The KDS undo (§5.2) can move an order back
# out of `ready` — `RollUpOrderStatus` nils `ready_at` on the way out — and
# re-finishing the drink re-enters it. So `ready_at` is not a once-only marker
# and cannot be used as the guard.
#
# This column is: set when the message is enqueued, never cleared, so the
# guarantee holds by construction rather than by hoping undo is rare.
class AddReadySmsSentAtToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :ready_sms_sent_at, :datetime
  end
end
