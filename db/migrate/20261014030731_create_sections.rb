class CreateSections < ActiveRecord::Migration[8.1]
  def change
    create_table :sections do |t|
      t.integer :Sec_num
      t.float :sec_width
      t.float :sec_length
      t.float :sec_depth
      t.float :sec_height
      t.references :aisle, null: false, foreign_key: true

      t.timestamps
    end
  end
end
