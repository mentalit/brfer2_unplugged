require "csv"

class PlanUploadService
  class UploadError < StandardError; end

  # voss_plan.csv, pallet_plan_2026-10-25.csv, pallet_plan_2026-10-25 2.csv
  FILENAME_FORMAT = /plan[\d_\- ]*\z/i
  ARTNO_LENGTH    = 8
  SLID_FORMAT     = /\A\d{6}\z/
  VOSS_SLID       = "990100"
  PALLET_SLID     = "PALLET"

  MODES = { voss: "voss", pallet: "pallet", aisles: "aisles" }.freeze

  # Only the columns on the plan CSV: Slid_h, artno, artname_unicode, new_slid
  ARTNO_COLUMN    = "artno"
  NEW_SLID_COLUMN = "new_slid"

  def initialize(store, file)
    @store = store
    @file  = file
  end

  def call
    check_filename!

    result = Hash.new(0)
    result[:missing_artnos]  = []
    result[:unplaced_slids]  = []

    rows  = read_csv
    plans = load_plans(rows, result)

    raise UploadError, "Plan file has no rows with an artno and new_slid." if plans.empty?

    articles = @store.articles.to_a.index_by { |a| artno_key(a.ARTNO) }

    Article.transaction do
      plans.each do |artno, slids|
        article = articles[artno]

        unless article
          result[:missing] += 1
          result[:missing_artnos] << artno
          next
        end

        locations = slids.filter_map do |slid|
          loc = location_for(slid)
          result[:unplaced_slids] << "#{artno} → #{slid}" unless loc
          loc
        end

        Placement.where(article_id: article.id).delete_all
        article.update_columns(new_slid: slids.first, planned: true)
        result[:articles_planned] += 1

        locations.each do |slid, section, level, mode|
          Placement.create!(
            store:    @store,
            article:  article,
            section:  section,
            level:    level,
            mode:     MODES[mode],
            new_slid: slid,
            quantity: quantity_for(article, level, mode)
          )
          result[:placements_created] += 1
        end
      end
    end

    Rails.logger.info "[PlanUpload] #{File.basename(filename)}: #{result.except(:missing_artnos, :unplaced_slids).inspect}"
    result
  end

  private

  # ---------- rows ----------

  # artno => [new_slid, ...] (an article on several rows gets every new_slid)
  def load_plans(rows, result)
    artno_col = column(rows.headers, ARTNO_COLUMN)
    slid_col  = column(rows.headers, NEW_SLID_COLUMN)

    unless artno_col && slid_col
      raise UploadError, "Plan file needs 'artno' and 'new_slid' columns. Headers seen: #{rows.headers.compact.join(', ')}"
    end

    rows.each_with_object({}) do |row, h|
      result[:rows] += 1
      artno = artno_key(row[artno_col])
      slid  = clean_slid(row[slid_col])

      if artno.blank? || slid.blank?
        result[:skipped_blank] += 1
        next
      end

      (h[artno] ||= []) << slid unless h[artno]&.include?(slid)
    end
  end

  # Digits only, padded with leading 0's to 8 characters: 500278 => "00500278"
  def artno_key(value)
    s = value.to_s.strip
    s = s.sub(/\.0+\z/, "") if s.match?(/\A\d+\.0+\z/)
    s = s.gsub(/\D/, "")
    s.blank? ? nil : s.rjust(ARTNO_LENGTH, "0")
  end

  # "990100", "990100.0", "PALLET", 5-digit slids get their leading 0 back
  def clean_slid(value)
    s = value.to_s.strip
    s = s.sub(/\.0+\z/, "") if s.match?(/\A\d+\.0+\z/)
    s = "0#{s}" if s.match?(/\A\d{5}\z/)
    s.match?(/\A\d+\z/) ? s : s.upcase.presence
  end

  # ---------- locations ----------

  # [slid, section, level, mode] or nil when the store has no matching aisle/section
  def location_for(slid)
    if slid == PALLET_SLID
      single_location(pallet_aisle, slid, :pallet)
    elsif slid == VOSS_SLID
      single_location(voss_aisle, slid, :voss)
    elsif SLID_FORMAT.match?(slid)
      aisle_location(slid)
    end
  end

  # Voss / PALLET aisles: first section, first level (level 00 created if none)
  def single_location(aisle, slid, mode)
    return nil unless aisle

    section = aisle.sections.to_a.min_by { |s| s.Sec_num.to_i }
    return nil unless section

    level = section.levels.to_a.min_by { |l| l.lev_num.to_i } ||
            section.levels.create!(lev_num: "00", lev_depth: section.sec_depth,
                                   lev_width: section.sec_width.to_s)
    [slid, section, level, mode]
  end

  # AASSLL: aisle AA, highest Sec_num at or below SS, level LL (created if missing)
  def aisle_location(slid)
    ss = slid[2, 2].to_i

    section = regular_aisles[slid[0, 2].to_i].to_a
      .filter_map { |aisle| aisle.sections.to_a.select { |s| s.Sec_num.to_i <= ss }.max_by { |s| s.Sec_num.to_i } }
      .max_by { |s| s.Sec_num.to_i }
    return nil unless section

    level = section.levels.to_a.find { |l| l.lev_num.to_i == slid[4, 2].to_i } ||
            section.levels.create!(lev_num: slid[4, 2], lev_depth: section.sec_depth,
                                   lev_width: section.sec_width.to_s)
    [slid, section, level, :aisles]
  end

  def all_aisles
    @all_aisles ||= @store.aisles.includes(sections: :levels).to_a
  end

  def pallet_aisle
    @pallet_aisle ||= all_aisles.find { |a| PalletPlannerService.pallet_aisle?(a) }
  end

  def voss_aisle
    @voss_aisle ||= all_aisles.find { |a| voss_aisle?(a) }
  end

  def voss_aisle?(aisle)
    %w[990100 VOSS].include?(aisle.aisle_num.to_s.strip.upcase)
  end

  # aisle number => aisles with that number (never the Voss or PALLET aisle)
  def regular_aisles
    @regular_aisles ||= all_aisles
      .reject { |a| voss_aisle?(a) || PalletPlannerService.pallet_aisle?(a) }
      .group_by { |a| a.aisle_num.to_i }
  end

  # Voss: RSSQ. PALLET: PALQ. Aisles: PALQ on level 00, MIN on upper levels.
  def quantity_for(article, level, mode)
    case mode
    when :voss   then article.RSSQ
    when :pallet then article.PALQ
    else level.lev_num.to_i.zero? ? article.PALQ : article.MIN
    end
  end

  # ---------- CSV ----------

  def filename
    @file.respond_to?(:original_filename) ? @file.original_filename.to_s : @file.to_s
  end

  def check_filename!
    base = File.basename(filename, ".*")
    unless File.extname(filename).casecmp?(".csv") && base.match?(FILENAME_FORMAT)
      raise UploadError, "#{File.basename(filename)} is not a plan CSV (name must end in plan, optionally with a date)."
    end
  end

  def column(headers, name)
    headers.compact.find { |h| norm(h) == norm(name) }
  end

  def norm(header)
    header.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def read_csv
    @file.rewind if @file.respond_to?(:rewind)
    raw  = @file.respond_to?(:read) ? @file.read : File.binread(@file)
    text = decode(raw).gsub("\r\n", "\n").gsub("\r", "\n")

    header_line = text.lines.first.to_s
    sep = ["\t", ";", ","].max_by { |s| header_line.count(s) }

    options = {
      headers: true,
      col_sep: sep,
      liberal_parsing: true,
      skip_blanks: true,
      header_converters: ->(h) { h.to_s.strip.delete('"') }
    }

    # Names like SUNNERSTA stor unit 22x15 " contain stray quotes
    CSV.parse(text, **options, quote_char: sep == "," ? '"' : "\x00")
  rescue CSV::MalformedCSVError
    CSV.parse(text, **options, quote_char: "\x00")
  end

  def decode(raw)
    raw = raw.b
    text =
      if raw.start_with?("\xFF\xFE".b)
        raw[2..].force_encoding("UTF-16LE").encode("UTF-8", invalid: :replace, undef: :replace)
      elsif raw.start_with?("\xFE\xFF".b)
        raw[2..].force_encoding("UTF-16BE").encode("UTF-8", invalid: :replace, undef: :replace)
      else
        utf8 = raw.dup.force_encoding("UTF-8")
        utf8.valid_encoding? ? utf8 : raw.dup.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
      end
    text.delete_prefix("\uFEFF").delete("\u0000")
  end
end