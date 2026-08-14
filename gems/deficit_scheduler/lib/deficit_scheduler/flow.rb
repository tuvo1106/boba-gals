module DeficitScheduler
  # A queue of related items competing as one unit — a "flow", in fair-queuing
  # terms.
  #
  # This is the whole architectural idea in one class: scheduling happens
  # *between* flows, not between items, so a flow holding fifteen items
  # competes for one turn of the ring rather than fifteen. That is what stops a
  # large batch from blocking every small one behind it.
  class Flow
    attr_reader :id, :arrived_at, :queue, :total_items, :deadline, :first_output_at
    attr_accessor :deficit

    # @param id [Object] opaque; a row id in most consumers
    # @param arrived_at [Time] drives aging — how long this flow has waited
    # @param queue [Array<DeficitScheduler::Item>] undispatched items, in order
    # @param total_items [Integer] size of the whole flow, including items
    #   already completed and gone from `queue`. Defaults to the queue size.
    # @param deadline [Time, nil] when this flow is due; nil means as-soon-as-
    #   possible. A flow with a deadline is scheduled *backward* from it rather
    #   than started immediately — see `Scheduler.eligible?`.
    # @param deficit [Integer, Float] carried across dispatch cycles; the
    #   unspent remainder is what the algorithm is named for
    # @param first_output_at [Time, nil] when this flow's earliest item was
    #   completed, and so when its partial output started going stale. nil until
    #   one completes. Drives the staleness boost.
    def initialize(id:, arrived_at:, queue:, total_items: nil,
                   deadline: nil, deficit: 0, first_output_at: nil)
      @id = id
      @arrived_at = arrived_at
      @queue = queue
      @total_items = total_items || queue.size
      @deadline = deadline
      @deficit = deficit
      @first_output_at = first_output_at
    end

    # @return [DeficitScheduler::Item, nil]
    def head
      queue.first
    end

    # @return [Boolean]
    def empty?
      queue.empty?
    end

    # Derived from the queue rather than stored as a flag. A cached boolean and
    # the queue it describes drift apart the moment an expedited item is
    # dispatched, and the failure — a flow keeping its priority tier forever —
    # is invisible until someone wonders why ordinary flows never win.
    # @return [Boolean]
    def pending_expedited?
      queue.any?(&:expedited?)
    end
  end
end
