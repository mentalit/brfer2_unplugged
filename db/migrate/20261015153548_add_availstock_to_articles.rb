class AddAvailstockToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :AVAILSTOCK, :integer
  end
end
