module Scheduler
  # One order's queue of drinks — a "flow" in fair-queuing terms (DESIGN.md §6.1).
  #
  # The order is the flow and the drink is the packet. That is the whole
  # architectural decision (§2) expressed in one class: scheduling happens
  # between flows, so a 15-drink order competes as *one* flow rather than as
  # fifteen queue entries.
  class Flow
    attr_reader :id, :arrived_at, :queue, :made_count, :total_items, :promised_at
    attr_accessor :deficit

    # @param id [Object] opaque; an Order id in production
    # @param arrived_at [Time] drives aging (§6.2)
    # @param queue [Array<Scheduler::Item>] undispatched drinks, in order
    # @param made_count [Integer] drinks already finished, for the cohesion boost
    # @param total_items [Integer] size of the whole order, including finished
    # @param promised_at [Time, nil] order-ahead target; nil means ASAP
    # @param deficit [Integer, Float] carried across dispatch cycles (§6.5)
    def initialize(id:, arrived_at:, queue:, made_count: 0, total_items: nil,
                   promised_at: nil, deficit: 0)
      @id = id
      @arrived_at = arrived_at
      @queue = queue
      @made_count = made_count
      @total_items = total_items || queue.size
      @promised_at = promised_at
      @deficit = deficit
    end

    # @return [Scheduler::Item, nil]
    def head
      queue.first
    end

    # @return [Boolean]
    def empty?
      queue.empty?
    end

    # Derived from the queue rather than stored as a flag. A cached boolean and
    # the queue it describes drift apart the moment a remake is dispatched, and
    # the failure — remakes keeping their priority floor forever — is invisible
    # until someone wonders why normal orders never win.
    # @return [Boolean]
    def pending_remake?
      queue.any?(&:remake?)
    end

    # @return [Float] 0.0 to 1.0
    def fraction_made
      made_count.to_f / total_items
    end
  end
end
