module Scheduler
  # One drink awaiting dispatch (DESIGN.md §6.2).
  #
  # A plain value object, not an OrderItem: the scheduler never touches
  # ActiveRecord, and the simulator (§10.1) builds these directly from its
  # generative model rather than from a database.
  class Item
    attr_reader :id, :prep_seconds, :enqueued_at

    # @param id [Object] opaque to the scheduler; an OrderItem id in production
    # @param prep_seconds [Integer] frozen at ordering (§4.1)
    # @param enqueued_at [Time]
    # @param remake [Boolean] whether this drink exists because an earlier one failed
    def initialize(id:, prep_seconds:, enqueued_at:, remake: false)
      @id = id
      @prep_seconds = prep_seconds
      @enqueued_at = enqueued_at
      @remake = remake
    end

    # @return [Boolean]
    def remake?
      @remake
    end
  end
end
