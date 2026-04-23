class CreateTimeTrackingTables < ActiveRecord::Migration[7.2]
  def change
    create_table :time_categories, id: :uuid do |t|
      t.string :name, null: false
      t.string :color, default: "#6172F3", null: false
      t.string :lucide_icon, default: "clock", null: false
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.uuid :parent_id
      t.timestamps
    end

    add_index :time_categories, :parent_id
    add_index :time_categories, %i[family_id name], unique: true
    add_foreign_key :time_categories, :time_categories, column: :parent_id

    create_table :time_blocks, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :time_category, foreign_key: true, type: :uuid
      t.datetime :started_at, null: false
      t.datetime :ended_at, null: false
      t.text :notes
      t.timestamps
    end

    add_index :time_blocks, %i[family_id started_at]
    add_index :time_blocks, %i[user_id started_at]
    add_index :time_blocks, :time_category_id, name: "index_time_blocks_on_time_category"
  end
end
