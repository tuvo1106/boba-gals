class CreateStaff < ActiveRecord::Migration[8.1]
  def change
    create_table :stations do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :name                           # "Bar 1", "Blender"
      t.boolean :active, default: true

      t.timestamps
    end

    create_table :baristas do |t|
      t.references :store, null: false, foreign_key: true
      t.string  :name
      t.string  :pin_digest                     # KDS login, bcrypt (§13.3)

      t.timestamps
    end

    # Dashboard and config auth (§13.4). Created by seed or console — there is
    # deliberately no signup, and no roles. Exists from the first deploy because
    # PATCH /admin/scheduler_config changes live scheduler behavior.
    create_table :admin_users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :admin_users, :email, unique: true
  end
end
