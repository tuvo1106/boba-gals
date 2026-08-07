# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_07_020400) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
  end

  create_table "baristas", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "pin_digest"
    t.bigint "store_id", null: false
    t.datetime "updated_at", null: false
    t.index ["store_id"], name: "index_baristas_on_store_id"
  end

  create_table "menu_items", force: :cascade do |t|
    t.boolean "available", default: true, null: false
    t.integer "base_prep_seconds", null: false
    t.string "category"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position"
    t.integer "price_cents", null: false
    t.bigint "store_id", null: false
    t.datetime "updated_at", null: false
    t.index ["store_id"], name: "index_menu_items_on_store_id"
  end

  create_table "option_groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "max_select", default: 1
    t.bigint "menu_item_id", null: false
    t.integer "min_select", default: 0
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "index_option_groups_on_menu_item_id"
  end

  create_table "options", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "option_group_id", null: false
    t.integer "prep_seconds_delta", default: 0
    t.integer "price_cents", default: 0
    t.datetime "updated_at", null: false
    t.index ["option_group_id"], name: "index_options_on_option_group_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "barista_id"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "label"
    t.bigint "menu_item_id", null: false
    t.bigint "order_id", null: false
    t.integer "prep_seconds", null: false
    t.datetime "queued_at"
    t.bigint "remake_of_id"
    t.string "remake_reason"
    t.jsonb "selected_options", default: []
    t.integer "sequence"
    t.datetime "started_at"
    t.bigint "station_id"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["barista_id"], name: "index_order_items_on_barista_id"
    t.index ["menu_item_id"], name: "index_order_items_on_menu_item_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["remake_of_id"], name: "index_order_items_on_remake_of_id"
    t.index ["station_id", "status"], name: "idx_items_active", where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'in_progress'::character varying])::text[]))"
    t.index ["station_id"], name: "index_order_items_on_station_id"
    t.index ["status", "queued_at"], name: "idx_items_dispatchable", where: "((status)::text = 'queued'::text)"
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customer_first_name"
    t.string "customer_phone"
    t.datetime "first_ready_at"
    t.datetime "picked_up_at"
    t.string "pickup_code", null: false
    t.datetime "placed_at"
    t.datetime "promised_at"
    t.integer "quoted_wait_seconds"
    t.datetime "ready_at"
    t.string "source", null: false
    t.string "status", null: false
    t.bigint "store_id", null: false
    t.integer "total_cents"
    t.datetime "updated_at", null: false
    t.index "store_id, pickup_code, ((placed_at)::date)", name: "idx_pickup_code_daily", unique: true
    t.index ["store_id", "status"], name: "idx_orders_open", where: "((status)::text <> ALL ((ARRAY['picked_up'::character varying, 'cancelled'::character varying])::text[]))"
    t.index ["store_id"], name: "index_orders_on_store_id"
  end

  create_table "prep_time_stats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "ewma_seconds"
    t.float "ewma_variance"
    t.bigint "menu_item_id", null: false
    t.integer "sample_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "idx_prep_stats_menu_item", unique: true
    t.index ["menu_item_id"], name: "index_prep_time_stats_on_menu_item_id"
  end

  create_table "scheduler_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.bigint "order_item_id"
    t.jsonb "payload", default: {}, null: false
    t.bigint "store_id", null: false
    t.datetime "updated_at", null: false
    t.index ["order_item_id"], name: "index_scheduler_events_on_order_item_id"
    t.index ["store_id", "occurred_at"], name: "index_scheduler_events_on_store_id_and_occurred_at"
    t.index ["store_id"], name: "index_scheduler_events_on_store_id"
  end

  create_table "stations", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.string "name"
    t.bigint "store_id", null: false
    t.datetime "updated_at", null: false
    t.index ["store_id"], name: "index_stations_on_store_id"
  end

  create_table "stores", force: :cascade do |t|
    t.boolean "accepting_orders", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.jsonb "scheduler_config", default: {}, null: false
    t.integer "station_count", default: 3, null: false
    t.string "timezone", default: "America/Los_Angeles", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "baristas", "stores"
  add_foreign_key "menu_items", "stores"
  add_foreign_key "option_groups", "menu_items"
  add_foreign_key "options", "option_groups"
  add_foreign_key "order_items", "baristas"
  add_foreign_key "order_items", "menu_items"
  add_foreign_key "order_items", "order_items", column: "remake_of_id"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "stations"
  add_foreign_key "orders", "stores"
  add_foreign_key "prep_time_stats", "menu_items"
  add_foreign_key "scheduler_events", "order_items"
  add_foreign_key "scheduler_events", "stores"
  add_foreign_key "stations", "stores"
end
