class CreateStores < ActiveRecord::Migration[8.1]
  def change
    create_table :stores do |t|
      t.string :store_name
      t.string :store_num

      t.timestamps
    end
  end
end
