# Learns how long an order's drinks typically spread apart, per size class
# (§9.6, #80).
#
# "ready_at - first_ready_at" is the same spread ADR-0014 measured by hand to
# show the flat quality_limit_seconds was blunt. This folds it into an EWMA per
# (store, size_class) the same way RecordPrepTime learns per-menu-item prep
# durations, so SweepQualityBreaches can flag a drink against what is actually
# typical for an order its size rather than one flat number for every order.
#
# Deliberately no outlier guard, unlike RecordPrepTime. That guard exists there
# to catch a barista who forgot to tap "finish" — a data error, not a real slow
# drink. There is no equivalent failure mode here: first_ready_at and ready_at
# are stamped automatically by RollUpOrderStatus, never by a tap that can be
# missed, so every order that reaches `ready` produced a real observation.
# Real spread also legitimately spans a wide range by nature of the problem
# (ADR-0014 measured p90s from ~100s to ~7500s+ across size classes alone), so
# there is no threshold that separates "erroneous" from "a genuinely slow
# order" the way there is for a single drink's prep time.
class RecordQualitySpread
  # Single-drink orders are the minimum, and it is what stops the "1-2" class
  # learning a threshold of zero (ADR-0035).
  MINIMUM_DRINKS = 2

  # @param order [Order] an order that just reached `ready`
  # @return [QualitySpreadStat, nil] the updated stat, or nil when nothing was learned
  def call(order)
    # **Learn from the same population the sweep judges.** `SweepQualityBreaches`
    # only ever flags a drink whose order is still `partially_ready` — waiting on
    # a sibling (ADR-0024) — which a single-drink order never is. But this used
    # to sample them anyway, and their spread is *definitionally* zero:
    # `RollUpOrderStatus` stamps `first_ready_at` and `ready_at` in the same call
    # when the only drink finishes.
    #
    # §10.3's size mix is ~62% single-drink, so after ten of them the "1-2"
    # class was `confident?` at an EWMA of ~0 with ~0 variance, `threshold_seconds`
    # collapsed to microseconds, and every 2-drink order was flagged the instant
    # its first drink finished — ADR-0031's own failure, reintroduced from the
    # other side.
    #
    # A zero from a solo order is a true fact about that order and says nothing
    # about how long a *pair's* first drink sits, which is the thing being
    # predicted.
    return nil if order.countable_items.size < MINIMUM_DRINKS

    observed = observed_seconds(order)
    return nil if observed.nil?

    size_class = order.size_class
    return nil if size_class.nil?

    stat = QualitySpreadStat.find_or_create_by!(store_id: order.store_id, size_class: size_class)
    stat.update!(**updated_values(stat, observed))
    stat
  end

  private

  # Zero is a legitimate observation — a single-drink order reaches
  # first_ready_at and ready_at in the same RollUpOrderStatus call, a real
  # zero-spread sample for the "1-2" class. Only a missing timestamp or a
  # clock that ran backwards is not an observation.
  def observed_seconds(order)
    return nil if order.first_ready_at.nil? || order.ready_at.nil?

    seconds = order.ready_at - order.first_ready_at
    seconds.negative? ? nil : seconds
  end

  def updated_values(stat, observed)
    previous = stat.ewma_seconds
    alpha = QualitySpreadStat::ALPHA

    # First sample seeds the average with itself; blending against nil would
    # otherwise make the first order's weight depend on nothing meaningful.
    ewma = previous.nil? ? observed : (alpha * observed) + ((1 - alpha) * previous)

    {
      ewma_seconds: ewma,
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
