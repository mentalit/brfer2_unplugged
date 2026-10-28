require "csv"

class ArticleRemovalService
  class UploadError < StandardError; end

  SPREADSHEET_EXTENSIONS = %w[.ods .xlsx .xls].freeze

  def initialize(store, file)
    @store = store
    @file  = file
  end

  # Deletes every article in the file (matched by ARTNO) and its placements,
  # so its SLID locations are free for planning
  def call
    rows   = read_csv(@file)
    header = rows.headers.compact.find { |h| norm(h) == "ARTNO" }
    raise UploadError, "No ARTNO column found. Headers seen: #{rows.headers.compact.first(8).join(', ')}" unless header

    keys = rows.filter_map { |r| key(r[header]).presence }.to_set
    raise UploadError, "The file has no article numbers — nothing was deleted." if keys.empty?

    matches = @store.articles.pluck(:id, :ARTNO, :Item_No, :SLID)
                    .select { |_id, artno, item_no, _slid| keys.include?(key(artno.presence || item_no)) }
    ids   = matches.map(&:first)
    found = matches.map { |_id, artno, item_no, _slid| key(artno.presence || item_no) }.to_set

    result = {
      requested:          keys.size,
      deleted:            0,
      placements_deleted: 0,
      freed_slids:        matches.sum { |m| Array(m[3]).reject(&:blank?).size },
      not_found:          (keys - found).map { |k| k.rjust(8, "0") }.sort
    }

    Article.transaction do
      result[:placements_deleted] = Placement.where(article_id: ids).delete_all
      result[:deleted]            = Article.where(id: ids).delete_all
    end

    result
  end

  private

  def norm(header)
    header.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  # Article number as digits only: "00377842", "377842", "3778.42" => "377842"
  def key(value)
    s = value.to_s.strip
    s = s.sub(/\.0+\z/, "") if s.match?(/\A\d+\.0+\z/)
    s.gsub(/\D/, "").sub(/\A0+(?=\d)/, "")
  end

  # CSV only — spreadsheet files are refused with a clear message
  def read_csv(file)
    name = file.respond_to?(:original_filename) ? file.original_filename.to_s : file.to_s
    if SPREADSHEET_EXTENSIONS.include?(File.extname(name).downcase)
      raise UploadError, "#{name} is a spreadsheet file. Save it as CSV and upload again."
    end

    file.rewind if file.respond_to?(:rewind)
    raw  = file.respond_to?(:read) ? file.read : File.binread(file)
    text = decode(raw).gsub("\r\n", "\n").gsub("\r", "\n")

    # Start at the header row (first line with ARTNO), skipping any title lines above it
    lines = text.lines
    idx   = lines.first(50).index { |l| l.split(/[\t;,]/).any? { |c| norm(c) == "ARTNO" } } || 0
    sep   = ["\t", ";", ","].max_by { |s| lines[idx].to_s.count(s) }
    body  = lines[idx..].join

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
end