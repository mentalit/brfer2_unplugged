require "csv"

class ArticleUploadService
  class UploadError < StandardError; end

  DIVISIONS = %w[SF WH].freeze

  # Al010 "Sales Method" → DIV. Every article with a blank DIV gets its DIV from here.
  SALES_METHOD_DIVS = { 1 => "SF", 2 => "WH" }.freeze

  # Articles starting on this date are uploaded even with missing fields:
  # Al010 articles not on the article file are created and the future-date rule is skipped.
  # They still need DIV SF or WH (a blank DIV comes from Al010 Sales Method 1 → SF, 2 → WH).
  FORCE_START_DATE = Date.new(2027, 1, 1)

  # Pre-planned rule: an article is imported as planned at its slid_h when
  # SRP != 4 OR End_Date_Sale != 2026-10-01 OR slid_h is not between these,
  # and the AislePlannerService would place it in place (see placeable_locations)
  PLANNING_END_DATE  = Date.new(2026, 10, 1)
  PLANNING_SLID_FROM = 590100
  PLANNING_SLID_TO   = 890000
  PLACEMENT_MODE     = "aisles"
  SLID_FORMAT        = /\A\d{6}\z/

  # Conversion factors to millimetres (unit written in the cell, otherwise mm)
  MM_FACTORS = {
    "mm" => 1.0, "cm" => 10.0, "m" => 1000.0,
    "in" => 25.4, "inch" => 25.4, "inches" => 25.4, "\"" => 25.4,
    "ft" => 304.8, "'" => 304.8
  }.freeze

  # attribute => [type, [CSV columns, in order]]
  # Only columns that exist in slm0003_export / SLM003_Dash.
  # Header matching ignores case, spaces and underscores.
  # For each field the first column with a usable value wins.
  ARTICLE_FIELDS = {
    "ARTNO"           => [:string,       ["Article Number", "ARTNO"]],
    "ARTNAME_UNICODE" => [:string,       ["Article Name", "ARTNAME_UNICODE"]],
    "SLID"            => [:array,        ["SLID"]],
    "DIV"             => [:string,       ["Division", "DIV"]],
    "hfb"             => [:integer,      ["HFB", "Home Furnishing Business"]],
    "pa"              => [:integer,      ["PA", "Product Area"]],
    "SRP"             => [:integer,      ["SRP"]],
    "FCST"            => [:float,        ["FCST"]],
    "ASSQ"            => [:integer,      ["ASSQ"]],
    "SSQ"             => [:integer,      ["SSQ"]],
    "DTFP"            => [:integer,      ["DTFP"]],
    "DTFP_PLUS"       => [:integer,      ["DTFP PLUS", "DTFP_PLUS"]],
    "MIN"             => [:integer,      ["MIN SSQ", "MIN"]],
    "MAX"             => [:integer,      ["MAX SSQ", "MAX"]],
    "RSSQ"            => [:integer,      ["RSSQ"]],
    "DT"              => [:integer,      ["DT"]],
    "MPQ"             => [:positive_int, ["MPQ", "Local MPQ", "Central MPQ"]],
    "PALQ"            => [:positive_int, ["PALQ", "Central PALQ"]],
    "AVAILSTOCK"      => [:integer,      ["Avail Stock", "AVAILSTOCK"]],
    # slm0003_export dates — DWP dates win when the item exists there
    "Start_Date_Sale" => [:date,         ["SSD"]],
    "End_Date_Sale"   => [:date,         ["EDS"]]
  }.freeze

  # DWP columns
  ITEM_FIELDS = {
    "Item_No"          => [:string,       ["Item No"]],
    "Start_Date_Sale"  => [:date,         ["Start Date Sale"]],
    "End_Date_Sale"    => [:date,         ["End Date Sale"]],
    "CP_Sale_Sol_Name" => [:string,       ["CP Sale Sol Name"]],
    "CP_Length"        => [:mm,           ["CP Length"]],
    "CP_Width"         => [:mm,           ["CP Width"]],
    "CP_Height"        => [:mm,           ["CP Height"]],
    "CP_Weight_Gross"  => [:string,       ["CP Weight Gross"]],
    "UL_Sale_Sol_Name" => [:string,       ["UL Sale Sol Name"]],
    "UL_Length_Gross"  => [:mm,           ["UL Length Gross"]],
    "UL_Width_Gross"   => [:mm,           ["UL Width Gross"]],
    "UL_Height_Gross"  => [:mm,           ["UL Height Gross"]],
    # fallbacks only — used when the slm file has no MPQ / PALQ for the article
    "_dwp_mpq"         => [:positive_int, ["MP Qty"]],
    "_dwp_palq"        => [:positive_int, ["UL Qty"]]
  }.freeze

  # Fill-only files: their values are used only where the slm + DWP left a field empty.
  # "_key" is each file's own article-number column.
  SLM0002_FIELDS = {
    "_key"            => [:string,  ["ARTNO"]],
    "CP_Height"       => [:mm,      ["CP_HEIGHT"]],
    "CP_Length"       => [:mm,      ["CP_LENGTH"]],
    "CP_Width"        => [:mm,      ["CP_WIDTH"]],
    "CP_Weight_Gross" => [:string,  ["CP_WEIGHT_GROSS"]],
    "UL_Height_Gross" => [:mm,      ["UL_HEIGHT_GROSS"]],
    "UL_Length_Gross" => [:mm,      ["UL_LENGTH_GROSS"]],
    "UL_Width_Gross"  => [:mm,      ["UL_WIDTH_GROSS"]],
    "NO_OF_PACKS"     => [:integer, ["NO_OF_PACKS"]]
  }.freeze

  AL010_FIELDS = {
    "_key"            => [:string,  ["Article Number"]],
    "ARTNAME_UNICODE" => [:string,  ["Article Name"]],
    "hfb"             => [:integer, ["HFB"]],
    "pa"              => [:integer, ["Product Area"]],
    "Start_Date_Sale" => [:date,    ["SSD"]],
    "End_Date_Sale"   => [:date,    ["EDS"]],
    # used only when the article has no DIV / no MIN / no DT (see apply_al010)
    "_sales_method"   => [:integer,      ["Sales Method"]],
    "_al010_mpq"      => [:positive_int, ["MPQ"]],
    "_del_type"       => [:integer,      ["Del Type"]]
  }.freeze

  # The article-number column that marks the header row in the article / DWP files
  MAIN_KEYS = ["Article Number", "ARTNO", "Item No"].freeze

  SPREADSHEET_EXTENSIONS = %w[.ods .xlsx .xls].freeze

  def initialize(store, article_file:, item_file: nil, slm0002_file: nil, al010_file: nil)
    @store        = store
    @article_file = article_file
    @item_file    = item_file
    @slm0002_file = slm0002_file
    @al010_file   = al010_file
  end

  def call
    today  = Date.current
    result = Hash.new(0)
    result[:missing_mpq_artnos] = []
    result[:div_blank_artnos]   = []

    # Work out which upload is which from the headers, whatever slot it was put in
    files        = [@article_file, @item_file].compact_blank.map { |f| read_csv(f, MAIN_KEYS) }
    article_rows = files.find { |rows| has_column?(rows.headers, ARTICLE_FIELDS["ARTNO"][1]) }
    item_rows    = files.find { |rows| !rows.equal?(article_rows) && has_column?(rows.headers, ITEM_FIELDS["Item_No"][1]) }

    unless article_rows
      raise UploadError, "Article file: no 'Article Number' or 'ARTNO' column found. Headers seen: #{headers_seen(files)}"
    end

    if files.size > 1 && item_rows.nil?
      other = files.reject { |rows| rows.equal?(article_rows) }
      raise UploadError, "DWP file: no 'Item No' column found. Headers seen: #{headers_seen(other)}"
    end

    article_map = present_map(article_rows.headers, ARTICLE_FIELDS)
    result[:mpq_columns] = (article_map.find { |m| m[0] == "MPQ" }&.last || []).join(", ").presence || "none"
    result[:item_file]   = item_rows ? "yes" : "no"

    items    = load_items(item_rows)
    slm0002  = load_fill(@slm0002_file, SLM0002_FIELDS, "SLM0002")
    al010    = load_fill(@al010_file, AL010_FIELDS, "Al010")
    articles = load_articles(article_rows, article_map, result)

    # Never wipe the store because of an empty or wrong article file
    if articles.empty?
      raise UploadError, "Article file has no articles — nothing was uploaded or deleted."
    end

    # Al010 articles starting 01/01/2027 that are not on the article file are uploaded too
    al010.each do |k, row|
      next if articles.key?(k) || row["Start_Date_Sale"] != FORCE_START_DATE
      articles[k] = { "ARTNO" => k.rjust(8, "0") }
      result[:al010_only_added] += 1
    end

    existing = @store.articles.to_a.index_by { |a| key(a.ARTNO.presence || a.Item_No) }

    result[:articles_total]  = articles.size
    result[:dwp_matched]     = articles.keys.count { |k| items.key?(k) }
    result[:slm0002_matched] = articles.keys.count { |k| slm0002.key?(k) }
    result[:al010_matched]   = articles.keys.count { |k| al010.key?(k) }

    # Pass 1: division + expired/no-stock rules
    candidates = []
    articles.each do |k, attrs|
      attrs = attrs.merge(items[k] || {}) # DWP values override SSD/EDS
      fill_blanks(attrs, slm0002[k])      # SLM0002 fills empty dimensions + NO_OF_PACKS
      article = existing[k]
      apply_al010(attrs, article, al010[k], result) # Al010 fills empty name, HFB, PA, dates, DT and DIV

      start_date = attrs.key?("Start_Date_Sale") ? attrs["Start_Date_Sale"] : article&.Start_Date_Sale
      end_date   = attrs.key?("End_Date_Sale")   ? attrs["End_Date_Sale"]   : article&.End_Date_Sale
      stock      = attrs.key?("AVAILSTOCK")      ? attrs["AVAILSTOCK"]      : article&.AVAILSTOCK
      div        = (attrs.key?("DIV") ? attrs["DIV"] : article&.DIV).to_s.strip.upcase
      forced     = start_date == FORCE_START_DATE

      # No DIV in any file and no Sales Method 1 / 2 in Al010 → not SF / WH, so not uploaded
      if div.empty?
        result[:div_blank] += 1
        result[:div_blank_artnos] << k
      end

      if !DIVISIONS.include?(div)
        result[:skipped_division] += 1
      elsif stock == 0 && end_date && end_date < today
        result[:skipped_expired_no_stock] += 1
      else
        candidates << [k, attrs, article, start_date, end_date, forced]
      end
    end

    # Next Start Date Sale — only from articles still eligible for upload (01/01/2027 ones are always uploaded)
    next_start = candidates.reject { |c| c[5] }.filter_map { |c| c[3] }.select { |d| d > today }.min

    Article.transaction do
      # Pass 2: future-date rule, then upload
      candidates.each do |k, attrs, article, start_date, end_date, forced|
        if !forced && start_date && start_date > today && start_date != next_start
          result[:skipped_future] += 1
          next
        end

        # MPQ is handled on its own so it is always written:
        # slm MPQ / Local MPQ / Central MPQ -> DWP MP Qty. 0 and blank never count.
        mpq      = attrs.delete("MPQ")
        dwp_mpq  = attrs.delete("_dwp_mpq")
        dwp_palq = attrs.delete("_dwp_palq")
        mpq      = dwp_mpq if mpq.nil?
        al010_mpq = attrs.delete("_al010_mpq")

        fill_from_fallback(attrs, article, "PALQ", dwp_palq)

        # No MIN (blank or 0) → MIN = MPQ, always
        min_set = min_from_mpq(attrs, article, mpq, al010_mpq)
        if min_set
          result[:min_from_mpq] += 1
          result[:min_from_al010] += 1 if al010_mpq && min_set == al010_mpq.to_i
        end

        srp       = attrs.key?("SRP") ? attrs["SRP"] : article&.SRP
        raw_slids = attrs["SLID"].presence || article&.SLID.to_a
        slids     = valid_slids(raw_slids)
        locations = []

        if manual_plan?(article, slids)
          # new_slid set by hand or by the planner — keep new_slid, planned and placements
          result[:manual_kept] += 1
        elsif pre_planned?(srp, end_date, slids.first)
          # Pre-planned: your rule + the planner's in-place rules
          if srp != 4 && !AislePlannerService.reserved_article?({ "SLID" => raw_slids })
            locations = placeable_locations(slids)
          end
          result[:rule_not_placeable] += 1 if locations.empty?
        end

        if locations.any?
          attrs["new_slid"] = locations.first[0]
          attrs["planned"]  = true
          result[:pre_planned] += 1
        end

        article ||= @store.articles.new
        article.assign_attributes(attrs)
        article.MPQ = mpq unless mpq.nil?

        status = article.new_record? ? :created : (article.changed? ? :updated : :unchanged)
        if article.save
          result[status] += 1
          result[:forced_uploaded] += 1 if forced
          create_placements(article, locations, result) if locations.any?
        else
          result[:failed] += 1
          Rails.logger.warn "[ArticleUpload] #{k} failed: #{article.errors.full_messages.join(', ')}"

          # Existing article failed validation — MPQ, and MIN from MPQ, still get written
          if article.persisted? && !mpq.nil?
            article.update_column(:MPQ, mpq)
            result[:mpq_forced] += 1
          end
          article.update_column(:MIN, min_set) if article.persisted? && min_set
        end

        if mpq.nil?
          result[:missing_mpq] += 1
          result[:missing_mpq_artnos] << k
        end
      end

      # Articles no longer on the article file (or added from Al010 above): delete them and their placements
      on_file = articles.keys.to_set
      gone    = @store.articles.pluck(:id, :ARTNO, :Item_No)
                      .reject { |_id, artno, item_no| on_file.include?(key(artno.presence || item_no)) }
                      .map(&:first)

      if gone.any?
        result[:placements_deleted] = Placement.where(article_id: gone).delete_all
        result[:deleted]            = Article.where(id: gone).delete_all
      end
    end

    result[:next_start_date] = next_start
    Rails.logger.info "[ArticleUpload] result: #{result.except(:missing_mpq_artnos, :div_blank_artnos).inspect}"
    result
  end

  private

  # SRP != 4 OR End_Date_Sale != 2026-10-01 OR slid_h not between 590100 and 890000
  # (an article with no SLID has no location, so it is never pre-planned)
  def pre_planned?(srp, end_date, slid_h)
    return false if slid_h.blank?

    in_range = slid_h.to_i.between?(PLANNING_SLID_FROM, PLANNING_SLID_TO)
    srp != 4 || end_date != PLANNING_END_DATE || !in_range
  end

  # An existing article whose new_slid is not one of its own SLIDs (old or new)
  # was planned by hand or relocated by the planner — the upload leaves that plan alone
  def manual_plan?(article, slids)
    return false if article.nil? || article.new_slid.blank?

    current = valid_slids([article.new_slid]).first || article.new_slid.to_s.strip
    own     = valid_slids(article.SLID) | slids
    !own.include?(current)
  end

  # ---------- placement rules — same as AislePlannerService ----------

  # 5-digit slids lost their leading zero (10400 → 010400); only AASSLL slids count
  def valid_slids(list)
    Array(list).map do |s|
      s = s.to_s.strip
      s.match?(/\A\d{5}\z/) ? "0#{s}" : s
    end.select { |s| SLID_FORMAT.match?(s) }.uniq
  end

  # [[slid, section, level], ...] for every slid in a plannable aisle
  # (not VOSS / 990100 / PALLET, not aisles 60–80).
  # Several aisles can share a number (12 FS, 12 SS): every one is checked and the
  # slid goes to the aisle whose section is closest (highest Sec_num at or below SS).
  def placeable_locations(slids)
    slids.filter_map do |slid|
      ss = slid[2, 2].to_i

      section = plannable_aisles[slid[0, 2].to_i].to_a
        .filter_map { |aisle| section_for(aisle, ss) }
        .max_by { |s| s.Sec_num.to_i }
      next unless section

      [slid, section, level_for(section, slid)]
    end
  end

  # aisle number => every plannable aisle with that number
  def plannable_aisles
    @plannable_aisles ||= @store.aisles.includes(sections: :levels).to_a
      .select { |a| AislePlannerService.plannable_aisle?(a) }
      .group_by { |a| a.aisle_num.to_i }
  end

  # A section spans several slid section numbers, so the slid goes to the
  # highest Sec_num at or below its SS
  def section_for(aisle, ss)
    aisle.sections.to_a.select { |s| s.Sec_num.to_i <= ss }.max_by { |s| s.Sec_num.to_i }
  end

  # The slid's level; a missing level is created like the planner does
  def level_for(section, slid)
    section.levels.to_a.find { |l| l.lev_num.to_i == slid[4, 2].to_i } ||
      section.levels.create!(lev_num: slid[4, 2], lev_depth: section.sec_depth,
                             lev_width: section.sec_width.to_s)
  end

  # One placement per location, replacing any earlier placements for this article.
  # Quantity: PALQ on level 00, MIN on upper levels.
  def create_placements(article, locations, result)
    Placement.where(article_id: article.id).delete_all

    locations.each do |slid, section, level|
      Placement.create!(
        store:    @store,
        article:  article,
        section:  section,
        level:    level,
        mode:     PLACEMENT_MODE,
        new_slid: slid,
        quantity: level.lev_num.to_i.zero? ? article.PALQ : article.MIN
      )
      result[:placements_created] += 1
    end
  end

  # ---------- CSV ----------

  def headers_seen(files)
    files.map { |rows| rows.headers.compact.first(8).join(", ") }.join(" | ")
  end

  # Al010 for one article:
  #   - fills empty name, HFB, PA and dates
  #   - no DIV (nil or blank): Sales Method 1 → SF, 2 → WH
  #   - no DT (nil or blank):  DT = Del Type
  #   - keeps Al010 MPQ for MIN (see min_from_mpq)
  # The article's saved value counts too, so an upload without a DIV / MIN column keeps what is there.
  def apply_al010(attrs, article, row, result)
    return if row.blank?

    sales_method = row["_sales_method"]
    al010_mpq    = row["_al010_mpq"]
    del_type     = row["_del_type"]
    fill_blanks(attrs, row.except("_sales_method", "_al010_mpq", "_del_type"))

    dt = attrs.key?("DT") ? attrs["DT"] : article&.DT
    if dt.to_s.strip.empty? && !del_type.nil?
      attrs["DT"] = del_type
      result[:dt_from_al010] += 1
    end

    div = attrs.key?("DIV") ? attrs["DIV"] : article&.DIV
    if div.blank? && (from_sales = SALES_METHOD_DIVS[sales_method])
      attrs["DIV"] = from_sales
      result[:div_from_al010] += 1
    end

    # Kept for pass 2, where MIN is filled from MPQ (Al010 MPQ first)
    attrs["_al010_mpq"] = al010_mpq if al010_mpq
  end

  # MIN blank or 0 → MPQ. Al010 MPQ first, then the upload's MPQ (slm / DWP), then the saved MPQ.
  # Returns the MIN that was set, or nil when MIN already had a value (or there is no MPQ anywhere).
  def min_from_mpq(attrs, article, mpq, al010_mpq)
    min = attrs.key?("MIN") ? attrs["MIN"] : article&.MIN
    return nil unless min.nil? || min.to_i.zero?

    fallback = al010_mpq || mpq || article&.MPQ
    return nil unless fallback.to_i.positive?

    attrs["MIN"] = fallback.to_i
  end

  # Copies values from extra into attrs only where attrs has nothing
  def fill_blanks(attrs, extra)
    return if extra.blank?
    extra.each { |a, v| attrs[a] = v if attrs[a].nil? && !v.nil? }
  end

  # Sets attr from the fallback only when the article would otherwise end up without a value
  def fill_from_fallback(attrs, article, attr, fallback)
    return if fallback.nil?
    current = attrs.key?(attr) ? attrs[attr] : article&.public_send(attr)
    attrs[attr] = fallback if current.nil?
  end

  # One entry per article. If an article appears on several rows,
  # every SLID from every row is collected into the SLID array, and any
  # field missing on the first row is filled from the later rows.
  def load_articles(rows, map, result)
    rows.each_with_object({}) do |row, h|
      attrs = map_row(row, map)
      k = key(attrs["ARTNO"])

      if k.blank?
        result[:skipped_no_artno] += 1
        next
      end

      if h.key?(k)
        h[k]["SLID"] = (h[k]["SLID"] + attrs["SLID"]).uniq if attrs.key?("SLID")
        attrs.each do |a, v|
          next if a == "SLID"
          h[k][a] = v if h[k][a].nil? && !v.nil?
        end
      else
        attrs["SLID"] = attrs["SLID"].uniq if attrs.key?("SLID")
        h[k] = attrs
      end
    end
  end

  def load_items(rows)
    return {} unless rows

    map = present_map(rows.headers, ITEM_FIELDS)

    rows.each_with_object({}) do |row, h|
      attrs = map_row(row, map)
      k = key(attrs["Item_No"])
      next if k.blank?

      if h.key?(k)
        # duplicate supplier rows: first row wins, blanks filled from later rows
        fill_blanks(h[k], attrs)
      else
        h[k] = attrs
      end
    end
  end

  # SLM0002 / Al010: article number => fields (first row wins, blanks filled from later rows)
  def load_fill(file, fields, name)
    return {} if file.blank?

    key_columns = fields["_key"][1]
    rows = read_csv(file, key_columns)
    unless has_column?(rows.headers, key_columns)
      raise UploadError, "#{name}: no #{key_columns.join(' / ')} column found. Headers seen: #{headers_seen([rows])}"
    end

    map = present_map(rows.headers, fields)

    rows.each_with_object({}) do |row, h|
      attrs = map_row(row, map)
      k = key(attrs.delete("_key"))
      next if k.blank?

      if h.key?(k)
        fill_blanks(h[k], attrs)
      else
        h[k] = attrs
      end
    end
  end

  def has_column?(headers, candidates)
    normalized = headers.compact.map { |h| norm(h) }
    candidates.any? { |c| normalized.include?(norm(c)) }
  end

  # Only columns that exist in the file are mapped (missing fields are never updated)
  # Returns [[attribute, type, [actual headers]], ...]
  def present_map(headers, fields)
    lookup = {}
    headers.compact.each { |h| lookup[norm(h)] ||= h }

    fields.filter_map do |attr, (type, candidates)|
      actual = candidates.filter_map { |c| lookup[norm(c)] }.uniq
      [attr, type, actual] if actual.any?
    end
  end

  # Takes the first column whose value casts to something usable
  def map_row(row, map)
    map.each_with_object({}) do |(attr, type, actual), h|
      h[attr] = actual.lazy.map { |a| cast(row[a], type) }.find { |v| !v.nil? }
      h[attr] = [] if type == :array && h[attr].nil?
    end
  end

  def norm(header)
    header.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  # Article number as digits only: "706.250.23", "70625023.0", "0070625023" => "70625023"
  def key(value)
    s = value.to_s.strip
    s = s.sub(/\.0+\z/, "") if s.match?(/\A\d+\.0+\z/)
    s.gsub(/\D/, "").sub(/\A0+(?=\d)/, "")
  end

  def cast(value, type)
    s = value.to_s.strip
    case type
    when :string       then s.presence
    when :integer      then (n = to_number(s)) ? n.round : nil
    when :positive_int then (n = to_number(s)) && n.round > 0 ? n.round : nil
    when :float        then to_number(s)
    when :mm           then to_mm(s)
    when :date         then parse_date(s)
    when :array        then (parts = s.split(/[,;|\s]+/).reject(&:blank?)).any? ? parts : nil
    end
  end

  # Whole millimetres as a string (the columns are strings).
  # Unit comes from the cell ("30.7 in", "78cm", '30.7"'), otherwise mm.
  def to_mm(s)
    return nil if s.blank?

    m = s.downcase.match(/\A(-?[\d.,]+)\s*(mm|cm|m|inches|inch|in|ft|"|')?\z/)
    return nil unless m

    n = to_number(m[1]) || to_number(m[1].tr(",", "."))
    return nil if n.nil?

    (n * MM_FACTORS.fetch(m[2] || "mm", 1.0)).round.to_s
  end

  def to_number(s)
    case s
    when /\A-?\d+(\.\d+)?\z/              then s.to_f
    when /\A-?\d{1,3}(,\d{3})+(\.\d+)?\z/ then s.delete(",").to_f
    end
  end

  def parse_date(s)
    return nil if s.blank?
    case s
    when %r{\A\d{1,2}/\d{1,2}/\d{4}\z} then Date.strptime(s, "%m/%d/%Y")
    when %r{\A\d{1,2}/\d{1,2}/\d{2}\z} then Date.strptime(s, "%m/%d/%y")
    else Date.parse(s)
    end
  rescue ArgumentError
    nil
  end

  # UTF-8 (with or without BOM), UTF-16 (Excel "Unicode Text") and Windows-1252
  def decode(raw)
    raw = raw.b
    text =
      if raw.start_with?("\xFF\xFE".b)
        raw[2..].force_encoding("UTF-16LE").encode("UTF-8", invalid: :replace, undef: :replace)
      elsif raw.start_with?("\xFE\xFF".b)
        raw[2..].force_encoding("UTF-16BE").encode("UTF-8", invalid: :replace, undef: :replace)
      elsif raw[0, 400].count("\x00") > 50
        enc = raw.start_with?("\x00".b) ? "UTF-16BE" : "UTF-16LE"
        raw.force_encoding(enc).encode("UTF-8", invalid: :replace, undef: :replace)
      else
        utf8 = raw.dup.force_encoding("UTF-8")
        utf8.valid_encoding? ? utf8 : raw.dup.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
      end
    text.delete_prefix("\uFEFF").delete("\u0000")
  end

  # CSV only — spreadsheet files are refused with a clear message
  def read_csv(file, header_keys)
    name = file.respond_to?(:original_filename) ? file.original_filename.to_s : file.to_s
    if SPREADSHEET_EXTENSIONS.include?(File.extname(name).downcase)
      raise UploadError, "#{name} is a spreadsheet file. Save it as CSV and upload again."
    end

    file.rewind if file.respond_to?(:rewind)
    raw = file.respond_to?(:read) ? file.read : File.binread(file)
    parse_text(decode(raw), header_keys)
  end

  # Starts at the real header row (the first line containing one of header_keys),
  # so report/title lines above it are skipped. Falls back to no quoting when a
  # file has broken quotes.
  def parse_text(text, header_keys)
    text  = text.gsub("\r\n", "\n").gsub("\r", "\n")
    lines = text.lines
    keys  = header_keys.map { |k| norm(k) }

    idx = lines.first(50).index do |l|
      (l.split(/[\t;,]/).map { |c| norm(c) } & keys).any?
    end || 0

    header_line = lines[idx].to_s
    sep  = ["\t", ";", ","].max_by { |s| header_line.count(s) }
    body = lines[idx..].join

    options = {
      headers: true,
      col_sep: sep,
      liberal_parsing: true,
      skip_blanks: true,
      header_converters: ->(h) { h.to_s.strip.delete('"') }
    }

    begin
      CSV.parse(body, **options, quote_char: sep == "," ? '"' : "\x00")
    rescue CSV::MalformedCSVError
      CSV.parse(body, **options, quote_char: "\x00")
    end
  end
end