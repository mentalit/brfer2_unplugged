class AddHfbAndPaToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :hfb, :integer
    add_column :articles, :pa, :integer
  end
end
