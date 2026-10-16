# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_16_011123) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "aisles", force: :cascade do |t|
    t.string "aisle_num"
    t.float "aisle_height"
    t.string "CHECKSTRING"
    t.string "LOC"
    t.string "TYPE"
    t.integer "MAXLENGTH"
    t.integer "MAXWIDTH"
    t.string "DIVISION"
    t.string "RACKTYPE"
    t.bigint "store_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["store_id"], name: "index_aisles_on_store_id"
  end

  create_table "articles", force: :cascade do |t|
    t.string "ARTNO"
    t.string "ARTNAME_UNICODE"
    t.string "SLID", default: [], array: true
    t.string "DIV"
    t.integer "ASSQ"
    t.integer "SSQ"
    t.integer "DTFP"
    t.integer "DTFP_PLUS"
    t.integer "MIN"
    t.integer "MAX"
    t.integer "RSSQ"
    t.integer "SRP"
    t.integer "DT"
    t.integer "PALQ"
    t.integer "MPQ"
    t.string "Item_No"
    t.string "CP_Sale_Sol_Name"
    t.string "CP_Length"
    t.string "CP_Width"
    t.string "CP_Height"
    t.string "CP_Weight_Gross"
    t.string "UL_Sale_Sol_Name"
    t.string "UL_Length_Gross"
    t.string "UL_Width_Gross"
    t.string "UL_Height_Gross"
    t.boolean "planned"
    t.string "new_slid"
    t.date "Start_Date_Sale"
    t.date "End_Date_Sale"
    t.bigint "store_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "FCST"
    t.string "linked_families", default: [], array: true
    t.integer "AVAILSTOCK"
    t.integer "hfb"
    t.integer "pa"
    t.index ["store_id"], name: "index_articles_on_store_id"
  end

  create_table "levels", force: :cascade do |t|
    t.string "lev_num"
    t.float "lev_depth"
    t.float "lev_height"
    t.string "lev_width"
    t.bigint "section_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["section_id"], name: "index_levels_on_section_id"
  end

  create_table "placements", force: :cascade do |t|
    t.bigint "store_id", null: false
    t.bigint "article_id", null: false
    t.bigint "section_id"
    t.bigint "level_id"
    t.string "mode"
    t.string "new_slid"
    t.integer "quantity"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_placements_on_article_id"
    t.index ["level_id"], name: "index_placements_on_level_id"
    t.index ["section_id"], name: "index_placements_on_section_id"
    t.index ["store_id"], name: "index_placements_on_store_id"
  end

  create_table "sections", force: :cascade do |t|
    t.integer "Sec_num"
    t.float "sec_width"
    t.float "sec_length"
    t.float "sec_depth"
    t.float "sec_height"
    t.bigint "aisle_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["aisle_id"], name: "index_sections_on_aisle_id"
  end

  create_table "stores", force: :cascade do |t|
    t.string "store_name"
    t.string "store_num"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "aisles", "stores"
  add_foreign_key "articles", "stores"
  add_foreign_key "levels", "sections"
  add_foreign_key "placements", "articles"
  add_foreign_key "placements", "stores"
  add_foreign_key "sections", "aisles"
end
