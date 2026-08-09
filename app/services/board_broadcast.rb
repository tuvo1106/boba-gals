# Pushes the customer board to every screen showing it (§9.2).
#
# Throttled to one broadcast per store per second, because the board is the
# highest-fanout channel in the system: every drink transition changes it, and a
# busy store transitions several drinks a second across every screen at once.
#
# The throttle is leading-edge with a trailing flush, not a plain drop. A plain
# drop loses whichever transition happens to be last in a burst, and that is the
# one people are looking at — a name would sit in Making after its drink was
# already handed over. The mechanism itself lives in `ThrottledBroadcast`.
class BoardBroadcast
  extend ThrottledBroadcast

  # §9.2: "Throttle board broadcasts to 1/sec."
  WINDOW = 1.second

  # Long enough to outlive the flush job's queue latency, short enough that a
  # crashed worker cannot suppress broadcasts for more than a few seconds.
  PENDING_TTL = 10.seconds

  # @param store [Store]
  # @return [String]
  def self.stream_name(store)
    "board:#{store.id}"
  end

  def self.throttle_name = "board"
  def self.window = WINDOW
  def self.pending_ttl = PENDING_TTL
  def self.flush_job = BoardFlushJob

  def self.publish(store)
    ActionCable.server.broadcast(stream_name(store), BoardView.call(store))
  end

  private_class_method :throttle_name, :window, :pending_ttl, :flush_job, :publish
end
