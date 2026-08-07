class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    # An Order is only a grouping and payment container. The unit of work is
    # OrderItem (§2) — do not let order-level scheduling creep back in.
    create_table :orders do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :source, null: false             # "kiosk" | "web"

      # The capability token for GET /orders/:pickup_code (§13.1). 4 chars from
      # a 30-char unambiguous alphabet, unique per store per day.
      t.string  :pickup_code, null: false

      t.string  :customer_first_name             # displayed on the board
      t.string  :customer_phone                  # web only, for SMS; never displayed (§13.5)
      t.string  :status, null: false             # §5.1

      t.datetime :placed_at
      t.datetime :promised_at                    # order-ahead target; nil = ASAP
      t.datetime :first_ready_at
      t.datetime :ready_at
      t.datetime :picked_up_at

      t.integer :quoted_wait_seconds             # ETA at order time; feeds ETA-error metrics (§10.4)
      t.integer :total_cents

      t.timestamps
    end

    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :menu_item, null: false, foreign_key: true

      # Denormalized snapshots, frozen at creation: [{option_id, name,
      # prep_seconds_delta}] and "Brown Sugar Pearl, 50%, less ice". A later
      # menu edit must not rewrite what a customer actually ordered.
      t.jsonb   :selected_options, default: []
      t.string  :label

      # base + sum(option deltas), frozen at creation (§4.1).
      t.integer :prep_seconds, null: false

      t.string  :status, null: false             # §5.2
      t.references :station, null: true, foreign_key: true
      t.references :barista, null: true, foreign_key: true

      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :finished_at

      # `finished` is terminal. A failed drink is never un-finished — a new row
      # is created pointing back here, which keeps prep-time statistics honest
      # and makes remakes visible in reporting (§5.2).
      t.references :remake_of, null: true, foreign_key: { to_table: :order_items }
      t.string  :remake_reason

      t.integer :sequence                        # position within its order, for display

      t.timestamps
    end

    # §4.2 — the indexes that matter. Partial, because the hot queries only ever
    # look at open work; finished and picked-up rows accumulate forever.
    add_index :order_items, [ :status, :queued_at ],
              where: "status = 'queued'",
              name: "idx_items_dispatchable"

    add_index :order_items, [ :station_id, :status ],
              where: "status IN ('queued', 'in_progress')",
              name: "idx_items_active"

    add_index :orders, [ :store_id, :status ],
              where: "status NOT IN ('picked_up', 'cancelled')",
              name: "idx_orders_open"

    # Buckets by UTC day, not store-local day — acceptable for a single-timezone
    # deployment (§4.2). If it ever matters, add a `business_date` column set at
    # placement in store time.
    add_index :orders, "store_id, pickup_code, (placed_at::date)",
              unique: true,
              name: "idx_pickup_code_daily"
  end
end
