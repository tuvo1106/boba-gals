# Applies a scheduler configuration change to a store (§6.6, §10.6).
#
# This is the write end of the dashboard's "Apply to store" action. It is also
# the only way live scheduler behaviour changes, which is why the endpoint sits
# behind admin auth from the first deploy (§13.4).
#
# Every key is validated against a fixed schema and unknown keys are rejected
# rather than merged. `stores.scheduler_config` must never accumulate anything
# that is not scheduler tuning — §14.6 is explicit that it must never hold a
# secret, and an allowlist is the only version of that rule which cannot be
# forgotten later.
class UpdateSchedulerConfig
  Result = Struct.new(:success?, :store, :errors, keyword_init: true)

  # Bounds are guardrails against a typo taking the shop down, not design
  # opinions — the design's own values sit comfortably inside every range.
  # Where a bound is load-bearing rather than arbitrary, it says so.
  SCHEMA = {
    # §6.3: FIFO is the control arm the whole fairness claim is measured against,
    # so it stays selectable rather than being a code branch nobody can reach.
    "policy" => { type: :enum, values: %w[drr fifo] },
    # §10.5 sweeps the quantum from 30s to 400s; the range is wider than the
    # sweep so the sweep's endpoints are not also the limits.
    "quantum" => { type: :integer, min: 10, max: 900 },
    "aging_enabled" => { type: :boolean },
    "aging_rate" => { type: :float, min: 0.0, max: 5.0 },
    "cohesion_enabled" => { type: :boolean },
    "cohesion_boost" => { type: :float, min: 0.0, max: 10.0 },
    # Below 1.0 the "priority floor" (§6.4) becomes a priority ceiling and
    # remakes rank *below* same-age normal work — the exact inversion of what
    # the multiplier exists to guarantee.
    "remake_multiplier" => { type: :float, min: 1.0, max: 50.0 },
    "promise_buffer" => { type: :integer, min: 0, max: 3600 },
    "quality_limit_seconds" => { type: :integer, min: 30, max: 3600 },
    # Below 1.0 is deliberately under-quoting every customer. §7.3 is blunt
    # about bias being the thing that destroys trust in the board.
    "eta_safety_factor" => { type: :float, min: 1.0, max: 3.0 }
  }.freeze

  # @param store [Store]
  # @param changes [Hash] partial config; only the keys present are changed
  # @return [UpdateSchedulerConfig::Result]
  def call(store:, changes:)
    changes = changes.to_h.stringify_keys
    errors = []

    unknown = changes.keys - SCHEMA.keys
    errors << "unknown setting(s): #{unknown.sort.join(', ')}" if unknown.any?

    coerced = {}
    changes.slice(*SCHEMA.keys).each do |key, raw|
      value, error = coerce(key, raw)
      error ? errors << error : coerced[key] = value
    end

    return Result.new(success?: false, errors: errors) if errors.any?

    # Merged, not replaced: a PATCH that names one key must not silently reset
    # the other nine to their defaults.
    store.update!(scheduler_config: store.effective_scheduler_config.merge(coerced))

    Result.new(success?: true, store: store, errors: [])
  end

  private

  def coerce(key, raw)
    rule = SCHEMA.fetch(key)

    case rule[:type]
    when :enum then coerce_enum(key, raw, rule)
    when :boolean then coerce_boolean(key, raw)
    when :integer then coerce_number(key, raw, rule) { |v| Integer(v, exception: false) }
    when :float then coerce_number(key, raw, rule) { |v| Float(v, exception: false) }
    end
  end

  def coerce_enum(key, raw, rule)
    value = raw.to_s

    return [ nil, "#{key} must be one of: #{rule[:values].join(', ')}" ] unless rule[:values].include?(value)

    [ value, nil ]
  end

  # Deliberately strict: only real booleans and the two strings a JSON client
  # might send. "maybe" is a mistake, and coercing it to false would apply a
  # scheduler change nobody asked for.
  def coerce_boolean(key, raw)
    return [ raw, nil ] if [ true, false ].include?(raw)
    return [ raw == "true", nil ] if %w[true false].include?(raw.to_s)

    [ nil, "#{key} must be true or false" ]
  end

  def coerce_number(key, raw, rule)
    # Integer("12abc") is nil rather than 12 — a partial parse would accept a
    # typo and apply whichever prefix happened to parse.
    value = yield(raw.is_a?(String) ? raw.strip : raw)

    return [ nil, "#{key} must be a number" ] if value.nil?
    return [ nil, "#{key} must be between #{rule[:min]} and #{rule[:max]}" ] unless value.between?(rule[:min], rule[:max])

    [ value, nil ]
  end
end
