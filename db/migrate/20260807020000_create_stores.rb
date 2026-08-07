class CreateStores < ActiveRecord::Migration[8.1]
  def change
    create_table :stores do |t|
      t.string  :name, null: false
      t.string  :timezone, null: false, default: "America/Los_Angeles"

      # Store-setup seed only. Runtime truth is `stations WHERE active` (§4.1).
      t.integer :station_count, null: false, default: 3

      # Scheduler tuning owned by the dashboard's apply-to-store flow (§6.6,
      # §10.6). Runtime configuration, never deploy config — and never a secret
      # (§14.6).
      t.jsonb   :scheduler_config, null: false, default: {}

      t.boolean :accepting_orders, null: false, default: true

      t.timestamps
    end
  end
end
