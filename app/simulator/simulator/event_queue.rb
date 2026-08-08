module Simulator
  # A binary min-heap of scheduled events (DESIGN.md §10.2).
  #
  # "Not tick-based. Maintain a priority queue of events and jump the clock to
  # the next one." Ticking a 12-hour day at one-second resolution is 43,200
  # iterations that mostly do nothing; jumping between events is a few thousand
  # that each do something, which is what puts a full day in single-digit
  # milliseconds and makes §10.5's sweeps practical.
  #
  # A sorted array would be simpler and O(n) per insert. At a few thousand
  # events that is survivable, but sweeps run thousands of days, and the
  # difference compounds.
  class EventQueue
    Event = Struct.new(:at, :type, :payload, :sequence, keyword_init: true)

    def initialize
      @heap = []
      @sequence = 0
    end

    def empty? = @heap.empty?
    def size = @heap.size

    # @param at [Float] simulated seconds
    # @param type [Symbol] one of §10.2's event types
    def push(at, type, payload = nil)
      @heap << Event.new(at: at, type: type, payload: payload, sequence: @sequence += 1)
      sift_up(@heap.size - 1)
      self
    end

    # @return [Simulator::EventQueue::Event, nil] the earliest event
    def pop
      return nil if @heap.empty?

      top = @heap.first
      last = @heap.pop

      unless @heap.empty?
        @heap[0] = last
        sift_down(0)
      end

      top
    end

    def peek = @heap.first

    private

    # Ties break on insertion order, so a run is reproducible from its seed
    # (§10.2). Comparing on time alone would let heap layout decide which of two
    # simultaneous events happens first, and heap layout depends on history.
    def before?(a, b)
      a.at == b.at ? a.sequence < b.sequence : a.at < b.at
    end

    def sift_up(index)
      while index.positive?
        parent = (index - 1) / 2
        break unless before?(@heap[index], @heap[parent])

        @heap[parent], @heap[index] = @heap[index], @heap[parent]
        index = parent
      end
    end

    def sift_down(index)
      loop do
        smallest = index
        [ (2 * index) + 1, (2 * index) + 2 ].each do |child|
          smallest = child if child < @heap.size && before?(@heap[child], @heap[smallest])
        end
        break if smallest == index

        @heap[smallest], @heap[index] = @heap[index], @heap[smallest]
        index = smallest
      end
    end
  end
end
