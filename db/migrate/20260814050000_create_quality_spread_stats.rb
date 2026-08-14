class CreateQualitySpreadStats < ActiveRecord::Migration[8.1]
  def change
    # EWMA of an order's spread — ready_at - first_ready_at — per size class
    # (§9.6, #80). Seeded multipliers over quality_limit_seconds win until this
    # is confident; see QualitySpreadStat::SEEDED_MULTIPLIERS.
    create_table :quality_spread_stats do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :size_class, null: false
      t.float   :ewma_seconds
      t.float   :ewma_variance
      t.integer :sample_count, null: false, default: 0

      t.timestamps
    end

    add_index :quality_spread_stats, [ :store_id, :size_class ], unique: true,
              name: "idx_quality_spread_store_size"
  end
end
