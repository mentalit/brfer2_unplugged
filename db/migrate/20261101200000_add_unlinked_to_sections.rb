class AddUnlinkedToSections < ActiveRecord::Migration[8.1]
  def change
    # true = this section keeps its own depth even though its aisle is back to back with another
    add_column :sections, :unlinked, :boolean, default: false, null: false
  end
end