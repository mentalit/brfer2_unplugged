class CreateArticles < ActiveRecord::Migration[8.1]
  def change
    create_table :articles do |t|
      t.string :ARTNO
      t.string :ARTNAME_UNICODE
      t.string :SLID, array: true, default: []
      t.string :DIV
      t.integer :ASSQ
      t.integer :SSQ
      t.integer :DTFP
      t.integer :DTFP_PLUS
      t.integer :MIN
      t.integer :MAX
      t.integer :RSSQ
      t.integer :SRP
      t.integer :DT
      t.integer :PALQ
      t.integer :MPQ
      t.string :Item_No
      t.string :CP_Sale_Sol_Name
      t.string :CP_Length
      t.string :CP_Width
      t.string :CP_Height
      t.string :CP_Weight_Gross
      t.string :UL_Sale_Sol_Name
      t.string :UL_Length_Gross
      t.string :UL_Width_Gross
      t.string :UL_Height_Gross
      t.boolean :planned
      t.string :new_slid
      t.date :Start_Date_Sale
      t.date :End_Date_Sale
      t.references :store, null: false, foreign_key: true

      t.timestamps
    end
  end
end
