require "csv"

class WarehouseDetailsImportService
  SECTION_UNIT_WIDTH   = 916.3
  DEFAULT_AISLE_HEIGHT = 2286.0
  DIVISION_SUFFIX      = { "WH" => "FS", "SF" => "SS" }.freeze

  def initialize(store, file)
    @store = store
    @file  = file
  end

  def call
    rows = read_rows.select { |r| DIVISION_SUFFIX.key?(r["DIVISION"]) && r["LOC"].present? }

    storage_rows = rows.select { |r| r["TYPE"] == "Storage" }
    sales_rows   = rows.select { |r| r["TYPE"] == "Sales" }

    aisles_count = 0

    ActiveRecord::Base.transaction do
      # ---------- AISLES ----------
      sales_rows.group_by { |r| aisle_num(r) }.each do |aisle_num, aisle_rows|
        aisle_rows = aisle_rows.sort_by { |r| loc(r) }
        first      = aisle_rows.first
        measure    = storage_measure(storage_rows, aisle_num, first["CHECKSTRING"])

        aisle = @store.aisles.find_or_initialize_by(aisle_num: aisle_num)
        aisle.assign_attributes(
          "aisle_height" => DEFAULT_AISLE_HEIGHT,
          "CHECKSTRING"  => first["CHECKSTRING"],
          "LOC"          => first["LOC"],
          "TYPE"         => first["TYPE"],
          "MAXLENGTH"    => measure && measure["MAXLENGTH"].presence&.to_i,
          "MAXWIDTH"     => measure && measure["MAXWIDTH"].presence&.to_i,
          "DIVISION"     => first["DIVISION"],
          "RACKTYPE"     => first["RACKTYPE"]
        )
        aisle.save!
        aisles_count += 1

        # ---------- SECTIONS ----------
        # One section per CHECKSTRING.
        aisle_rows.group_by { |r| r["CHECKSTRING"] }.each do |_checkstring, checkstring_rows|
          zero_rows = checkstring_rows.select { |r| loc(r)[4..5] == "00" }
          next if zero_rows.empty?

          sec_num   = loc(zero_rows.first)[2..3].to_i
          sec_width = (zero_rows.size * SECTION_UNIT_WIDTH).round(1)
          sec_depth = aisle["MAXLENGTH"]

          section = aisle.sections.find_or_initialize_by("Sec_num" => sec_num)
          section.assign_attributes(sec_width: sec_width, sec_depth: sec_depth)
          section.save!

          # ---------- LEVELS ----------
          # Only level 00 on creation.
          level = section.levels.find_or_initialize_by(lev_num: "00")
          level.assign_attributes(lev_depth: section.sec_depth, lev_width: section.sec_width.to_s)
          level.save!
        end
      end
    end

    aisles_count
  end

  private

  def read_rows
    path = @file.respond_to?(:path) ? @file.path : @file
    text = File.read(path, encoding: "bom|utf-8")
    sep  = text.lines.first.to_s.include?("\t") ? "\t" : ","

    CSV.parse(text, headers: true, col_sep: sep, liberal_parsing: true,
                    header_converters: ->(h) { h.to_s.strip })
       .map { |r| r.to_h.transform_values { |v| v.to_s.strip } }
  end

  # "03-01-00" => "030100"
  def loc(row)
    row["LOC"].to_s.delete("-").strip
  end

  # WH => "03 FS", SF => "03 SS"
  def aisle_num(row)
    "#{loc(row)[0..1]} #{DIVISION_SUFFIX[row['DIVISION']]}"
  end

  # Storage row with the same CHECKSTRING first, otherwise any Storage row in the same aisle.
  def storage_measure(storage_rows, aisle_num, checkstring)
    storage_rows.find { |r| r["CHECKSTRING"] == checkstring && aisle_num(r) == aisle_num } ||
      storage_rows.find { |r| aisle_num(r) == aisle_num }
  end
end