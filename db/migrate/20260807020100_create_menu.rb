class CreateMenu < ActiveRecord::Migration[8.1]
  def change
    create_table :menu_items do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :name, null: false
      t.string  :category                       # milk_tea, fruit_tea, slush, specialty
      t.integer :base_prep_seconds, null: false
      t.integer :price_cents, null: false
      t.boolean :available, null: false, default: true
      t.integer :position                       # display order

      t.timestamps
    end

    # Sweetness, Ice, Toppings, Size.
    create_table :option_groups do |t|
      t.references :menu_item, null: false, foreign_key: true
      t.string  :name, null: false
      t.integer :min_select, default: 0
      t.integer :max_select, default: 1

      t.timestamps
    end

    # 50% sugar, Extra pearls, Large.
    create_table :options do |t|
      t.references :option_group, null: false, foreign_key: true
      t.string  :name, null: false
      t.integer :price_cents, default: 0

      # Extra pearls => +15. Summed into order_items.prep_seconds at creation
      # and frozen there, so a later menu edit never rewrites history (§4.1).
      t.integer :prep_seconds_delta, default: 0

      t.timestamps
    end
  end
end
