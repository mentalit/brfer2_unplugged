require "csv"

class ArticleUploadService
  class UploadError < StandardError; end

  DIVISIONS = %w[SF WH].freeze

  # attribute => [type, [CSV headers to try, in order]]
  # Covers both slm0003_export and SLM003_Dash headers.
  # Header matching ignores case, spaces and underscores.
  # For each field the first candidate column with a usable value wins.
  ARTICLE_FIELDS = {
    "ARTNO"           => [:string,       ["Article Number", "ARTNO"]],
    "ARTNAME_UNICODE" => [:string,       ["Article Name", "ARTNAME_UNICODE"]],
    "SLID"            => [:array,        ["SLID"]],
    "DIV"             => [:string,       ["Division", "DIV"]],
    "hfb"             => [:integer,      ["HFB", "Home Furnishing Business"]],
    "pa"              => [:integer,      ["PA", "Product Area"]],
    "planned"         => [:boolean,      ["Planned"]],
    "SRP"             => [:integer,      ["SRP"]],
    "FCST"            => [:float,        ["FCST"]],
    "ASSQ"            => [:integer,      ["ASSQ"]],
    "SSQ"             => [:integer,      ["SSQ"]],
    "DTFP"            => [:integer,      ["DTFP"]],
    "DTFP_PLUS"       => [:integer,      ["DTFP PLUS"]],
    "MIN"             => [:integer,      ["MIN SSQ", "MIN"]],
    "MAX"             => [:integer,      ["MAX SSQ", "MAX"]],
    "RSSQ"            => [:integer,      ["RSSQ"]],
    "DT"              => [:integer,      ["DT"]],
    "MPQ"             => [:positive_int, ["MPQ", "Local MPQ", "Central MPQ"]],
    "PALQ"            => [:positive_int, ["PALQ", "Central PALQ"]],
    "AVAILSTOCK"      => [:integer,      ["Avail Stock"]],
    # fallback dates — DWP dates win when the item exists there
    "Start_Date_Sale" => [:date,         ["SSD"]],
    "End_Date_Sale"   => [:date,         ["EDS"]]
  }.freeze

  ITEM_FIELDS = {
    "Item_No"          => [:string,       ["Item No"]],
    "Start_Date_Sale"  => [:date,         ["Start Date Sale"]],
    "End_Date_Sale"    => [:date,         ["End Date Sale"]],
    "CP_Sale_Sol_Name" => [:string,       ["CP Sale Sol Name"]],
    "CP_Length"        => [:string,       ["CP Length"]],
    "CP_Width"         => [:string,       ["CP Width"]],
    "CP_Height"        => [:string,       ["CP Height"]],
    "CP_Weight_Gross"  => [:string,       ["CP Weight Gross"]],
    "UL_Sale_Sol_Name" => [:string,       ["UL Sale Sol Name"]],
    "UL_Length_Gross"  => [:string,       ["UL Length Gross"]],
    "UL_Width_Gross"   => [:string,       ["UL Width Gross"]],
    "UL_Height_Gross"  => [:string,       ["UL Height Gross"]],
    # fallbacks only — used when the slm file has no MPQ / PALQ for the article
    "_dwp_mpq"         => [:positive_int, ["MP Qty"]],
    "_dwp_palq"        => [:positive_int, ["UL Qty"]]
  }.freeze

  def initialize(store, article_file:, item_file: nil)
    @store        = store
    @article_file = article_file
    @item_file    = item_file
  end

  def call
    today  = Date.current
    result = Hash.new(0)
    result[:missing_mpq_artnos] = []

    # Work out which upload is which from the headers, whatever slot it was put in
    files        = [@article_file, @item_file].compact_blank.map { |f| read_csv(f) }
    article_rows = files.find { |rows| has_column?(rows.headers, ARTICLE_FIELDS["ARTNO"][1]) }
    item_rows    = files.find { |rows| !rows.equal?(article_rows) && has_column?(rows.headers, ITEM_FIELDS["Item_No"][1]) }

    unless article_rows
      found = files.map { |rows| rows.headers.compact.first(8).join(", ") }.join(" | ")
      raise UploadError, "No 'Article Number' or 'ARTNO' column found. Headers seen: #{found}"
    end

    article_map = present_map(article_rows.headers, ARTICLE_FIELDS)
    result[:mpq_columns]  = (article_map.find { |m| m[0] == "MPQ" }&.last || []).join(", ").presence || "none"
    result[:item_file]    = item_rows ? "yes" : "no"

    items    = load_items(item_rows)
    articles = load_articles(article_rows, article_map, result)
    existing = @store.articles.to_a.index_by { |a| key(a.ARTNO.presence || a.Item_No) }

    result[:articles_total] = articles.size
    result[:dwp_matched]    = articles.keys.count { |k| items.key?(k) }

    # Pass 1: division + expired/no-stock rules
    candidates = []
    articles.each do |k, attrs|
      attrs   = attrs.merge(items[k] || {}) # DWP values override SSD/EDS
      article = existing[k]

      start_date = attrs.key?("Start_Date_Sale") ? attrs["Start_Date_Sale"] : article&.Start_Date_Sale
      end_date   = attrs.key?("End_Date_Sale")   ? attrs["End_Date_Sale"]   : article&.End_Date_Sale
      stock      = attrs.key?("AVAILSTOCK")      ? attrs["AVAILSTOCK"]      : article&.AVAILSTOCK

      if !DIVISIONS.include?(attrs["DIV"].to_s.strip.upcase)
        result[:skipped_division] += 1
      elsif stock == 0 && end_date && end_date < today
        result[:skipped_expired_no_stock] += 1
      else
        candidates << [k, attrs, article, start_date]
      end
    end

    # Next Start Date Sale — only from articles still eligible for upload
    next_start = candidates.filter_map { |c| c[3] }.select { |d| d > today }.min

    # Pass 2: future-date rule, then upload
    Article.transaction do
      candidates.each do |k, attrs, article, start_date|
        if start_date && start_date > today && start_date != next_start
          result[:skipped_future] += 1
          next
        end

        # MPQ is handled on its own so it is always written:
        # slm MPQ / Local MPQ / Central MPQ -> DWP MP Qty. 0 and blank never count.
        mpq      = attrs.delete("MPQ")
        dwp_mpq  = attrs.delete("_dwp_mpq")
        dwp_palq = attrs.delete("_dwp_palq")
        mpq      = dwp_mpq if mpq.nil?

        fill_from_fallback(attrs, article, "PALQ", dwp_palq)

        if article.nil?
          article = @store.articles.new
          attrs   = attrs.except("planned") # new articles are never planned
        end

        article.assign_attributes(attrs)
        article.MPQ = mpq unless mpq.nil?

        status = article.new_record? ? :created : (article.changed? ? :updated : :unchanged)
        if article.save
          result[status] += 1
        else
          result[:failed] += 1
          Rails.logger.warn "[ArticleUpload] #{k} failed: #{article.errors.full_messages.join(', ')}"

          # Existing article failed validation — MPQ still gets written
          if article.persisted? && !mpq.nil?
            article.update_column(:MPQ, mpq)
            result[:mpq_forced] += 1
          end
        end

        if mpq.nil?
          result[:missing_mpq] += 1
          result[:missing_mpq_artnos] << k
        end
      end
    end

    result[:next_start_date] = next_start
    Rails.logger.info "[ArticleUpload] result: #{result.except(:missing_mpq_artnos).inspect}"
    result
  end

  private

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
        attrs.each { |a, v| h[k][a] = v if h[k][a].nil? && !v.nil? }
      else
        h[k] = attrs
      end
    end
  end

  def has_column?(headers, candidates)
    normalized = headers.compact.map { |h| norm(h) }
    candidates.any? { |c| normalized.include?(norm(c)) }
  end

  # Only columns that exist in the CSV are mapped (missing fields are never updated)
  # Returns [[attribute, type, [actual headers]], ...]
  def present_map(headers, fields)
    lookup = {}
    headers.compact.each { |h| lookup[norm(h)] ||= h }

    fields.filter_map do |attr, (type, candidates)|
      actual = candidates.filter_map { |c| lookup[norm(c)] }.uniq
      [attr, type, actual] if actual.any?
    end
  end

  # Takes the first candidate column whose value casts to something usable
  def map_row(row, map)
    map.each_with_object({}) do |(attr, type, actual), h|
      h[attr] = actual.lazy.map { |a| cast(row[a], type) }.find { |v| !v.nil? }
      h[attr] = [] if type == :array && h[attr].nil?
      h[attr] = false if type == :boolean && h[attr].nil?
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
    when :date         then parse_date(s)
    when :boolean      then s.blank? ? nil : %w[yes y true 1].include?(s.downcase)
    when :array        then (parts = s.split(/[,;|\s]+/).reject(&:blank?)).any? ? parts : nil
    end
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

  def read_csv(file)
    file.rewind if file.respond_to?(:rewind)
    raw  = file.respond_to?(:read) ? file.read : File.binread(file)
    text = raw.dup.force_encoding("UTF-8")
    text = raw.dup.force_encoding("Windows-1252").encode("UTF-8") unless text.valid_encoding?
    text = text.delete_prefix("\uFEFF")

    first_line = text[0, text.index("\n") || text.size]
    sep = ["\t", ";", ","].max_by { |s| first_line.count(s) }

    CSV.parse(
      text,
      headers: true,
      col_sep: sep,
      quote_char: sep == "," ? '"' : "\x00", # names contain " (e.g. 4 ¾ ")
      liberal_parsing: true,
      skip_blanks: true,
      header_converters: ->(h) { h.to_s.strip }
    )
  end
end