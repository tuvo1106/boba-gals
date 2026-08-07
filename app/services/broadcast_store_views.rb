# Fans a state change out to every live view of the store (§9.2).
#
# One call site rather than two. The kitchen and the board are different views
# of the same drinks, and the failure mode of broadcasting them separately is
# that a new transition updates one and not the other — which reads to staff as
# "the board is broken" long after the cause is forgettable.
#
# Called after commit, never inside a transaction (§8).
class BroadcastStoreViews
  # @param store [Store]
  # @return [void]
  def self.call(store)
    KitchenBroadcast.call(store)
    BoardBroadcast.call(store)
  end
end
