module DeficitScheduler
  # One unit of work awaiting dispatch — a "packet", in fair-queuing terms.
  #
  # A plain value object with no persistence of its own: the scheduler never
  # touches a database, and a simulator can build these directly from a
  # generative model rather than from stored rows.
  class Item
    attr_reader :id, :cost, :enqueued_at

    # @param id [Object] opaque to the scheduler; a row id in most consumers
    # @param cost [Numeric] how much service this item needs, in the same unit
    #   as `Config#quantum`. The deficit is drawn down by exactly this much.
    # @param enqueued_at [Time] tiebreak only — FIFO order, and the secondary
    #   sort under the shortest-job comparison arm
    # @param expedited [Boolean] whether this item belongs to the priority tier.
    #   A flow holding one outranks same-age normal work outright rather than
    #   merely earning a bigger share — see `Scheduler.priority_ring`.
    def initialize(id:, cost:, enqueued_at:, expedited: false)
      @id = id
      @cost = cost
      @enqueued_at = enqueued_at
      @expedited = expedited
    end

    # @return [Boolean]
    def expedited?
      @expedited
    end
  end
end
