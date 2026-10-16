class CreatePlacements < ActiveRecord::Migration[8.1]
  def change
    create_table :placements do |t|
      t.references :store, null: false, foreign_key: true
      t.references :article, null: false, foreign_key: true
      t.bigint :section_id
      t.bigint :level_id
      t.string :mode
      t.string :new_slid
      t.integer :quantity

      t.timestamps
    end
    add_index :placements, :section_id
    add_index :placements, :level_id
  end
end
