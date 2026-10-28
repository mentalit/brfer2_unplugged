class AddNoOfPacksToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :NO_OF_PACKS, :integer
  end
end
