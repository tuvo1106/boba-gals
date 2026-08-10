# Folds a finished drink's duration into the EWMA (§7.3) — a full KDS undo
# window (§5.2) after the finish, rather than at the moment of it.
#
# §5.2 requires undo to discard the prep-time sample, and an EWMA cannot be
# cleanly un-blended. So nothing is learned until there is nothing left to undo:
# `FinishDrink` enqueues this with a `UndoLastAction::WINDOW` delay, and a
# mistap that gets undone simply never reaches a recorder (ADR-0019).
class RecordPrepTimeJob < ApplicationJob
  queue_as :default

  # @param item_id [Integer]
  # @param finished_at [Time] the finish this job was enqueued for
  # @return [void]
  def perform(item_id, finished_at)
    item = OrderItem.find_by(id: item_id)
    return if item.nil?

    return unless still_the_same_finish?(item, finished_at)

    RecordPrepTime.new.call(item)
  end

  private

  # Re-read here, not trusted from the enqueue, because the whole point of the
  # delay is that the item can have moved in the meantime (§5.2).
  #
  # `finished_at` is the token that makes this exactly-once. An undo followed by
  # a re-finish enqueues two jobs and both find the item `finished`, so status
  # alone would count one drink twice; matching the timestamp means each job
  # only records the finish it was scheduled for, and the undone one matches
  # nothing. Comparing the stamp rather than elapsed time keeps that true even
  # when a backlogged queue runs both jobs late, and needs no new column.
  #
  # Equality is exact rather than fuzzy on purpose: the column and the
  # serialized argument are both microsecond-precision, and a tolerance wide
  # enough to be worth having would let a re-finish double-count again.
  def still_the_same_finish?(item, finished_at)
    item.status == "finished" && item.finished_at == finished_at
  end
end
