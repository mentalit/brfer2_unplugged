require "csv"

class WarehouseDetailsImportService
  SECTION_UNIT_WIDTH   = 916.3   # mm
  DEFAULT_AISLE_HEIGHT = 2286.0  # mm
  CM_TO_MM             = 10
  DIVISION_SUFFIX      = { "WH" => "FS", "SF" => "SS" }.freeze

  def initialize(store, file)
    @store = store
    @file  = file
  end

  def call
    rows = read_rows.select { |r| DIVISION_SUFFIX.key?(r["DIVISION"]) && r["LOC"].present? }

    storage_rows = rows.select { |r| r["TYPE"] == "STORAGE" }
    sales_rows   = rows.select { |r| r["TYPE"] == "SALES" }

    Rails.logger.info "[WarehouseImport] usable rows=#{rows.size} sales=#{sales_rows.size} storage=#{storage_rows.size}"

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
          "TYPE"         => "Sales",
          "MAXLENGTH"    => cm_to_mm(measure && measure["MAXLENGTH"]),
          "MAXWIDTH"     => cm_to_mm(measure && measure["MAXWIDTH"]),
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

  def cm_to_mm(value)
    value.presence && (value.to_f * CM_TO_MM).round
  end

  def read_rows
    text = read_text
    header_line = text.lines.first.to_s
    sep = ["\t", ";", ","].max_by { |s| header_line.count(s) }

    Rails.logger.info "[WarehouseImport] separator=#{sep.inspect} header=#{header_line.strip.inspect}"

    CSV.parse(text, headers: true, col_sep: sep, liberal_parsing: true,
                    header_converters: ->(h) { h.to_s.strip.upcase })
       .map do |r|
         h = r.to_h.transform_values { |v| v.to_s.strip }
         h["TYPE"]     = h["TYPE"].to_s.upcase
         h["DIVISION"] = h["DIVISION"].to_s.upcase
         h
       end
  end

  def read_text
    path = @file.respond_to?(:path) ? @file.path : @file
    raw  = File.binread(path)

    if raw.start_with?("\xFF\xFE".b)
      raw.byteslice(2..).force_encoding("UTF-16LE").encode("UTF-8")
    elsif raw.start_with?("\xFE\xFF".b)
      raw.byteslice(2..).force_encoding("UTF-16BE").encode("UTF-8")
    else
      raw = raw.byteslice(3..) if raw.start_with?("\xEF\xBB\xBF".b)
      text = raw.force_encoding("UTF-8")
      text.valid_encoding? ? text : text.encode("UTF-8", "Windows-1252", invalid: :replace, undef: :replace)
    end
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