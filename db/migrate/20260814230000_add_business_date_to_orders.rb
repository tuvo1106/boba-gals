class AddBusinessDateToOrders < ActiveRecord::Migration[8.1]
  # The shop's own day, not UTC's (§13.1, ADR-0036).
  #
  # `pickup_code` is unique per store per *day*, and both the uniqueness index
  # and every lookup used `(placed_at)::date` — a UTC date, because
  # `config.time_zone` is unset. For a store in America/Los_Angeles that rolls
  # the day over at 17:00 local, mid-service: an order placed at 16:58 became
  # unfindable by its own pickup code seven minutes later, and its code was
  # considered free and reissued to the next customer. Since the pickup code is
  # the capability token (§13.1), the first customer's status page then rendered
  # the second customer's order.
  #
  # A plain column rather than an expression index, because the correct
  # expression needs `stores.timezone` and a Postgres index expression cannot
  # reach another table.
  def up
    add_column :orders, :business_date, :date

    # Backfill per store, since each carries its own timezone. `AT TIME ZONE
    # 'UTC' AT TIME ZONE <tz>` reads the stored timestamp as UTC and renders it
    # in the store's zone, which is exactly what the application now computes.
    execute(<<~SQL.squish)
      UPDATE orders
      SET business_date = (
        (orders.placed_at AT TIME ZONE 'UTC' AT TIME ZONE stores.timezone)::date
      )
      FROM stores
      WHERE stores.id = orders.store_id
        AND orders.placed_at IS NOT NULL
    SQL

    # Any row with no placed_at at all (a draft that never got one) falls back
    # to its creation date rather than blocking the NOT NULL below.
    execute("UPDATE orders SET business_date = created_at::date WHERE business_date IS NULL")

    change_column_null :orders, :business_date, false

    remove_index :orders, name: "idx_pickup_code_daily"
    add_index :orders, [ :store_id, :pickup_code, :business_date ],
              unique: true, name: "idx_pickup_code_daily"
  end

  def down
    remove_index :orders, name: "idx_pickup_code_daily"
    add_index :orders, "store_id, pickup_code, ((placed_at)::date)",
              unique: true, name: "idx_pickup_code_daily"
    remove_column :orders, :business_date
  end
end
