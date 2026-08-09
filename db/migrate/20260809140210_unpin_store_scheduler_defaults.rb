# Drops materialised defaults out of `stores.scheduler_config` (§6.6).
#
# `UpdateSchedulerConfig` used to merge into `effective_scheduler_config`, so a
# PATCH naming one key wrote all ten. Every store an admin had ever touched was
# therefore pinned to the defaults of that day, and the §10.5 quantum change
# would have reached none of them. The service now stores only what was actually
# set; this clears what the old behaviour left behind.
#
# Only keys whose stored value still *equals the old default* are removed — a
# genuine override is kept. The two cannot be told apart when they happen to
# coincide, so a deliberate `quantum: 120` is indistinguishable from a
# materialised one and will be dropped back to the new default of 60. That is
# the right trade here: nothing is in production, the single seeded store never
# had a deliberate override, and the alternative is leaving every store frozen
# on old defaults forever.
class UnpinStoreSchedulerDefaults < ActiveRecord::Migration[8.1]
  # The defaults as they stood *before* §10.5 lowered the quantum. Frozen into
  # the migration rather than read from `Store::SCHEDULER_DEFAULTS`, which will
  # keep changing — a migration has to mean the same thing when it is replayed
  # in two years (ADR-0007's `db:prepare` runs these on a fresh cluster).
  PREVIOUS_DEFAULTS = {
    "policy" => "drr",
    "quantum" => 120,
    "aging_enabled" => true,
    "aging_rate" => 0.15,
    "cohesion_enabled" => false,
    "cohesion_boost" => 1.0,
    "remake_multiplier" => 4.0,
    "promise_buffer" => 120,
    "quality_limit_seconds" => 300,
    "eta_safety_factor" => 1.15
  }.freeze

  def up
    say_with_time "unpinning materialised scheduler defaults" do
      Store.reset_column_information

      Store.find_each do |store|
        config = store.scheduler_config || {}
        kept = config.reject { |key, value| PREVIOUS_DEFAULTS[key] == value }

        next if kept == config

        store.update_columns(scheduler_config: kept)
      end
    end
  end

  # Irreversible in the strict sense — the information about which keys were
  # explicitly set is what this discards, and it cannot be reconstructed. Down
  # is a no-op rather than a raise so a rollback of a later migration in the
  # same batch is not blocked by this one; the effective config is unchanged
  # either way, because the defaults fill the gaps.
  def down
    # No-op. See above.
  end
end
