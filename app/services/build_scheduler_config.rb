# Translates this shop's scheduler settings into the scheduler's own vocabulary
# (ADR-0033).
#
# The scheduler ships as a domain-neutral gem: it knows about flows, items,
# costs and deadlines, and nothing about drinks, remakes or melting boba. This
# app knows the opposite. `KEY_MAP` is the whole of the difference, and it is
# deliberately the *only* place the two vocabularies meet — §6.6's key names
# stay exactly as they are in `stores.scheduler_config`, in the admin API, in
# the OpenAPI document and on the dashboard, so nothing customer- or
# operator-facing had to churn for a refactor.
#
# Keys the scheduler does not read (`quality_limit_seconds`,
# `eta_safety_factor`) fall through untouched and are dropped by
# `Config.from_h` — they belong to the quality timer (§9.6) and the ETA
# projection (§7.1).
class BuildSchedulerConfig
  # §6.6's name => the gem's name. Anything absent is passed through unchanged,
  # which covers the keys both sides already agree on (`policy`, `quantum`,
  # `aging_enabled`, `aging_rate`).
  KEY_MAP = {
    "cohesion_enabled" => :staleness_enabled,
    "cohesion_boost" => :staleness_boost,
    "remake_multiplier" => :expedited_multiplier,
    "promise_buffer" => :deadline_buffer
  }.freeze

  # @param settings [Hash] §6.6 config, string- or symbol-keyed. Accepts a
  #   `Store#effective_scheduler_config` directly, and also the symbol-keyed
  #   hashes the simulator's scenarios build.
  # @return [DeficitScheduler::Config]
  def self.call(settings)
    translated = settings.to_h.map { |key, value| [ KEY_MAP.fetch(key.to_s, key.to_sym), value ] }

    DeficitScheduler::Config.from_h(translated.to_h)
  end
end
