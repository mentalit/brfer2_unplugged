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

ActiveRecord::Schema[8.1].define(version: 2026_10_14_030731) do
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
  add_foreign_key "sections", "aisles"
end
