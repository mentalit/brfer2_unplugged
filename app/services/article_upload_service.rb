require "csv"

class ArticleUploadService
  DIVISIONS = %w[SF WH].freeze

  # attribute => [type, [CSV headers to try, in order]]
  # Header matching ignores case, spaces and underscores.
  ARTICLE_FIELDS = {
    "ARTNO"           => [:string,  ["Article Number"]],
    "ARTNAME_UNICODE" => [:string,  ["Article Name"]],
    "SLID"            => [:array,   ["SLID"]],
    "DIV"             => [:string,  ["Division"]],
    "planned"         => [:boolean, ["Planned"]],
    "SRP"             => [:integer, ["SRP"]],
    "FCST"            => [:float,   ["FCST"]],
    "ASSQ"            => [:integer, ["ASSQ"]],
    "SSQ"             => [:integer, ["SSQ"]],
    "DTFP"            => [:integer, ["DTFP"]],
    "DTFP_PLUS"       => [:integer, ["DTFP PLUS"]],
    "MIN"             => [:integer, ["MIN SSQ"]],
    "MAX"             => [:integer, ["MAX SSQ"]],
    "RSSQ"            => [:integer, ["RSSQ"]],
    "DT"              => [:integer, ["DT"]],
    "MPQ"             => [:integer, ["Local MPQ", "Central MPQ"]],
    "PALQ"            => [:integer, ["Central PALQ"]],
    "AVAILSTOCK"      => [:integer, ["Avail Stock"]],
    # fallback dates — DWP dates win when the item exists there
    "Start_Date_Sale" => [:date,    ["SSD"]],
    "End_Date_Sale"   => [:date,    ["EDS"]]
  }.freeze

  ITEM_FIELDS = {
    "Item_No"          => [:string, ["Item No"]],
    "Start_Date_Sale"  => [:date,   ["Start Date Sale"]],
    "End_Date_Sale"    => [:date,   ["End Date Sale"]],
    "CP_Sale_Sol_Name" => [:string, ["CP Sale Sol Name"]],
    "CP_Length"        => [:string, ["CP Length"]],
    "CP_Width"         => [:string, ["CP Width"]],
    "CP_Height"        => [:string, ["CP Height"]],
    "CP_Weight_Gross"  => [:string, ["CP Weight Gross"]],
    "UL_Sale_Sol_Name" => [:string, ["UL Sale Sol Name"]],
    "UL_Length_Gross"  => [:string, ["UL Length Gross"]],
    "UL_Width_Gross"   => [:string, ["UL Width Gross"]],
    "UL_Height_Gross"  => [:string, ["UL Height Gross"]]
  }.freeze

  def initialize(store, article_file:, item_file: nil)
    @store        = store
    @article_file = article_file
    @item_file    = item_file
  end

  def call
    today  = Date.current
    result = Hash.new(0)

    items      = load_items
    next_start = items.values.filter_map { |a| a["Start_Date_Sale"] }.select { |d| d > today }.min

    articles = load_articles(result)
    existing = @store.articles.to_a.index_by { |a| key(a.ARTNO.presence || a.Item_No) }

    Article.transaction do
      articles.each do |k, attrs|
        unless DIVISIONS.include?(attrs["DIV"].to_s.strip.upcase)
          result[:skipped_division] += 1
          next
        end

        attrs   = attrs.merge(items[k] || {}) # DWP values override SSD/EDS
        article = existing[k]

        start_date = attrs.key?("Start_Date_Sale") ? attrs["Start_Date_Sale"] : article&.Start_Date_Sale
        end_date   = attrs.key?("End_Date_Sale")   ? attrs["End_Date_Sale"]   : article&.End_Date_Sale
        stock      = attrs.key?("AVAILSTOCK")      ? attrs["AVAILSTOCK"]      : article&.AVAILSTOCK

        if stock == 0 && end_date && end_date < today
          result[:skipped_expired_no_stock] += 1
          next
        end

        if start_date && start_date > today && start_date != next_start
          result[:skipped_future] += 1
          next
        end

        article ||= @store.articles.new
        article.assign_attributes(attrs)

        status = article.new_record? ? :created : (article.changed? ? :updated : :unchanged)
        if article.save
          result[status] += 1
        else
          result[:failed] += 1
          Rails.logger.warn "[ArticleUpload] #{k} failed: #{article.errors.full_messages.join(', ')}"
        end
      end
    end

    result[:next_start_date] = next_start
    Rails.logger.info "[ArticleUpload] result: #{result.inspect}"
    result
  end

  private

  # One entry per article. If an article appears on several rows,
  # every SLID from every row is collected into the SLID array.
  def load_articles(result)
    rows = read_csv(@article_file)
    map  = present_map(rows.headers, ARTICLE_FIELDS)

    rows.each_with_object({}) do |row, h|
      attrs = map_row(row, map)
      k = key(attrs["ARTNO"])

      if k.blank?
        result[:skipped_no_artno] += 1
        next
      end

      if h.key?(k)
        h[k]["SLID"] = (h[k]["SLID"] + attrs["SLID"]).uniq if attrs.key?("SLID")
      else
        attrs["SLID"] = attrs["SLID"].uniq if attrs.key?("SLID")
        h[k] = attrs
      end
    end
  end

  def load_items
    return {} if @item_file.blank?

    rows = read_csv(@item_file)
    map  = present_map(rows.headers, ITEM_FIELDS)

    rows.each_with_object({}) do |row, h|
      attrs = map_row(row, map)
      k = key(attrs["Item_No"])
      next if k.blank? || h.key?(k) # first row wins (duplicate supplier rows)
      h[k] = attrs
    end
  end

  # Only columns that exist in the CSV are mapped (missing fields are never updated)
  # Returns [[attribute, type, [actual headers]], ...]
  def present_map(headers, fields)
    lookup = {}
    headers.compact.each { |h| lookup[norm(h)] ||= h }

    fields.filter_map do |attr, (type, candidates)|
      actual = candidates.filter_map { |c| lookup[norm(c)] }
      [attr, type, actual] if actual.any?
    end
  end

  # Uses the first non-blank value among the candidate columns
  def map_row(row, map)
    map.each_with_object({}) do |(attr, type, actual), h|
      value = actual.map { |a| row[a] }.find { |v| v.to_s.strip.present? }
      h[attr] = cast(value, type)
    end
  end

  def norm(header)
    header.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def key(value)
    value.to_s.strip.sub(/\A0+(?=\d)/, "")
  end

  def cast(value, type)
    s = value.to_s.strip
    case type
    when :string  then s.presence
    when :integer then (n = to_number(s)) ? n.round : nil
    when :float   then to_number(s)
    when :date    then parse_date(s)
    when :boolean then s.blank? ? nil : %w[yes y true 1].include?(s.downcase)
    when :array   then s.split(/[,;|\s]+/).reject(&:blank?)
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

    CSV.parse(
      text,
      headers: true,
      liberal_parsing: true,
      skip_blanks: true,
      header_converters: ->(h) { h.to_s.strip }
    )
  end
end