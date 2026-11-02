class AddLinkedAisleToAisles < ActiveRecord::Migration[8.1]
  def change
    # The aisle on the other side of a back-to-back rack (both aisles point at each other)
    add_reference :aisles, :linked_aisle, null: true,
                  foreign_key: { to_table: :aisles, on_delete: :nullify }
  end
end
