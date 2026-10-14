class CreateAisles < ActiveRecord::Migration[8.1]
  def change
    create_table :aisles do |t|
      t.string :aisle_num
      t.float :aisle_height
      t.string :CHECKSTRING
      t.string :LOC
      t.string :TYPE
      t.integer :MAXLENGTH
      t.integer :MAXWIDTH
      t.string :DIVISION
      t.string :RACKTYPE
      t.references :store, null: false, foreign_key: true

      t.timestamps
    end
  end
end
