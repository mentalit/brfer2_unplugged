class AddFcstAndLinkedFamiliesToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :FCST, :float
    add_column :articles, :linked_families, :string, array: true, default: []
  end
end
