# Pushes the customer board to every screen showing it (§9.2).
#
# Throttled to one broadcast per store per second, because the board is the
# highest-fanout channel in the system: every drink transition changes it, and a
# busy store transitions several drinks a second across every screen at once.
#
# The throttle is leading-edge with a trailing flush, not a plain drop. A plain
# drop loses whichever transition happens to be last in a burst, and that is the
# one people are looking at — a name would sit in Making after its drink was
# already handed over.
#
# The window lives in Redis rather than in a class variable because `web` runs 2
# replicas (§14.2, §14.4): two pods with independent in-process windows throttle
# to 2/sec, and neither can see the other's pending flush.
class BoardBroadcast
  # §9.2: "Throttle board broadcasts to 1/sec."
  WINDOW = 1.second

  # Long enough to outlive the flush job's queue latency, short enough that a
  # crashed worker cannot suppress broadcasts for more than a few seconds.
  PENDING_TTL = 10.seconds

  # @param store [Store]
  # @return [void]
  def self.call(store)
    if open_window?(store)
      publish(store)
    else
      schedule_flush(store)
    end
  end

  # The trailing edge. Called only by BoardFlushJob, which is why it publishes
  # unconditionally — the whole point of the flush is that the window was closed
  # when the change happened.
  # @param store [Store]
  # @return [void]
  def self.flush(store)
    BobaGals::REDIS.with { |redis| redis.del(pending_key(store)) }
    open_window?(store)
    publish(store)
  end

  # @param store [Store]
  # @return [String]
  def self.stream_name(store)
    "board:#{store.id}"
  end

  # `SET NX PX` is atomic across pods — exactly one caller in any given second
  # gets a true back, and the key expires on its own so a crash cannot wedge the
  # board shut.
  def self.open_window?(store)
    BobaGals::REDIS.with do |redis|
      redis.set(window_key(store), 1, nx: true, px: WINDOW.in_milliseconds)
    end
  end

  # Also `SET NX`, so a burst of fifty transitions in one window enqueues one
  # flush rather than fifty.
  def self.schedule_flush(store)
    claimed = BobaGals::REDIS.with do |redis|
      redis.set(pending_key(store), 1, nx: true, px: PENDING_TTL.in_milliseconds)
    end

    BoardFlushJob.set(wait: WINDOW).perform_later(store.id) if claimed
  end

  def self.publish(store)
    ActionCable.server.broadcast(stream_name(store), BoardView.call(store))
  end

  def self.window_key(store)
    BobaGals.redis_key("board", "throttle", store.id)
  end

  def self.pending_key(store)
    BobaGals.redis_key("board", "pending", store.id)
  end

  private_class_method :open_window?, :schedule_flush, :publish, :window_key, :pending_key
end
