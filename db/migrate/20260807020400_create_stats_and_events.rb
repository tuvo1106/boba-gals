class CreateStatsAndEvents < ActiveRecord::Migration[8.1]
  def change
    # EWMA of observed durations (§7.3). Seeded base_prep_seconds will be wrong;
    # this is what makes the board's ETAs trustworthy instead of decorative.
    create_table :prep_time_stats do |t|
      t.references :menu_item, null: false, foreign_key: true
      t.float   :ewma_seconds
      t.float   :ewma_variance
      t.integer :sample_count, null: false, default: 0

      t.timestamps
    end

    add_index :prep_time_stats, :menu_item_id, unique: true, name: "idx_prep_stats_menu_item"

    # Append-only audit trail and the simulator's replay source (§4.1, §10.5).
    # Grows forever by design — at this volume that is megabytes per month.
    # Never prune before replay calibration has used them (§15).
    create_table :scheduler_events do |t|
      t.references :store, null: false, foreign_key: true

      # order_placed, item_queued, item_started, item_finished, item_remade,
      # order_ready, order_picked_up, quality_breach
      t.string :event_type, null: false

      t.references :order_item, null: true, foreign_key: true
      t.jsonb :payload, null: false, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :scheduler_events, [ :store_id, :occurred_at ]
  end
end
