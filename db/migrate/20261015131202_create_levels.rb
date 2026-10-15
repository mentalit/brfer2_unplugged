class CreateLevels < ActiveRecord::Migration[8.1]
  def change
    create_table :levels do |t|
      t.string :lev_num
      t.float :lev_depth
      t.float :lev_height
      t.string :lev_width
      t.references :section, null: false, foreign_key: true

      t.timestamps
    end
  end
end
