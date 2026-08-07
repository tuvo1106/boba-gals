# Pushes the current kitchen view to every subscribed KDS (§9.2).
#
# Called after commit, never inside a transaction (§8). Broadcasting mid-
# transaction would publish state that a rollback then un-does, and subscribers
# have no way to learn they were told a lie.
class KitchenBroadcast
  # @param store [Store]
  # @return [void]
  def self.call(store)
    ActionCable.server.broadcast(stream_name(store), KitchenQueue.call(store))
  end

  # Store-scoped, which is also what makes the Redis keyspace multi-store safe
  # without further work (§14.4, §16).
  # @param store [Store]
  # @return [String]
  def self.stream_name(store)
    "kitchen:#{store.id}"
  end
end
