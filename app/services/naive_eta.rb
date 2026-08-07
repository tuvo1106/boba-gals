# Placeholder wait estimate: outstanding prep work divided by active stations.
#
# This is the build step 3 estimate, and it is deliberately crude. §7.1 replaces
# it with a forward projection that runs the real scheduler against the current
# queue, because a formula like this drifts the moment the quantum changes — it
# has no idea that fair queuing reorders work.
#
# Until then it exists so POST /orders can honor its documented response shape
# (§9.1) rather than returning nil and teaching clients that the field is
# optional.
class NaiveEta
  # @param store [Store]
  # @return [Integer] estimated seconds until the whole order is ready
  def self.for_store(store)
    outstanding = OrderItem.active
                           .joins(:order)
                           .where(orders: { store_id: store.id })
                           .sum(:prep_seconds)

    stations = [ store.active_stations.count, 1 ].max

    (outstanding.to_f / stations).ceil
  end
end
