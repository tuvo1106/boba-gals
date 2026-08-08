# Learns how long a drink actually takes (DESIGN.md §7.3).
#
# "Seeded `base_prep_seconds` will be wrong. Maintain an EWMA per menu item from
# observed `finished_at - started_at`." Those seeds are guesses — 40s for a Thai
# Tea, 95s for a Brown Sugar Pearl — and §7.3 is blunt about the stakes: this is
# "the difference between a board customers trust and one they learn to ignore".
#
# An EWMA rather than a plain mean because a plain mean over a thousand drinks
# barely moves for the next one, so a new barista or a changed recipe would take
# a month to show up. An EWMA always moves by `ALPHA`, so it tracks the shop as
# it is rather than as it has been on average since opening (§17).
class RecordPrepTime
  # §7.3: "Discard samples outside [0.25x, 4x] of current EWMA — those are a
  # barista who forgot to tap 'finish', not a slow drink." A twenty-minute Thai
  # Tea is a missed tap, and one of them would drag the learned value far enough
  # to quote every later customer wrong.
  OUTLIER_FLOOR = 0.25
  OUTLIER_CEILING = 4.0

  # @param item [OrderItem] a finished drink
  # @return [PrepTimeStat, nil] the updated stat, or nil when nothing was learned
  def call(item)
    observed = observed_seconds(item)
    return nil if observed.nil?

    stat = PrepTimeStat.find_or_create_by!(menu_item_id: item.menu_item_id)
    return stat if outlier?(stat, observed)

    stat.update!(**updated_values(stat, observed))
    stat
  end

  private

  # A remade drink's duration is a real observation of making that drink, so it
  # counts. What does not count is a duration the model cannot have produced:
  # an unstarted or unfinished drink, or a clock that ran backwards.
  def observed_seconds(item)
    return nil if item.started_at.nil? || item.finished_at.nil?

    seconds = item.finished_at - item.started_at
    seconds.positive? ? seconds : nil
  end

  # Bounded against the *current* EWMA, not against the seed — the guard has to
  # move with the learned value or it would keep rejecting reality once the shop
  # genuinely got faster. Nothing is an outlier before there is an EWMA to be an
  # outlier from.
  def outlier?(stat, observed)
    return false if stat.ewma_seconds.blank?

    observed < stat.ewma_seconds * OUTLIER_FLOOR || observed > stat.ewma_seconds * OUTLIER_CEILING
  end

  def updated_values(stat, observed)
    previous = stat.ewma_seconds
    alpha = PrepTimeStat::ALPHA

    # First sample seeds the average with itself; blending against nil would
    # otherwise make the first drink's weight depend on the seeded guess.
    ewma = previous.nil? ? observed : (alpha * observed) + ((1 - alpha) * previous)

    {
      ewma_seconds: ewma,
      # EWMA of the squared deviation, on the same alpha. §7.1's safety factor
      # is a blunt multiplier applied to every item equally; knowing which items
      # are *erratic* rather than merely slow is what would let it stop being
      # one (§7.3, §10.4).
      ewma_variance: variance_for(previous, stat.ewma_variance, observed, alpha),
      sample_count: stat.sample_count + 1
    }
  end

  def variance_for(previous_ewma, previous_variance, observed, alpha)
    return 0.0 if previous_ewma.nil?

    deviation = observed - previous_ewma

    ((1 - alpha) * (previous_variance.to_f + (alpha * deviation * deviation))).round(4)
  end
end
