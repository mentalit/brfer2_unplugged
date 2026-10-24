class AislePlannerService
  # All measurements are in mm (articles CP_/UL_, sections, levels, aisles); weights in grams
  MODE               = "aisles"
  MANUAL_MODE        = "manual"
  EXCLUDED_AISLES    = %w[VOSS 990100 PALLET].freeze
  RESERVED_SLIDS     = %w[PALLET 990101].freeze
  NO_LOCATION        = (60..80)
  GROUND             = 0
  HEAVY_WEIGHT_G     = 22679.6
  KG_TO_G            = 1000
  DEFAULT_SEC_HEIGHT = 2286.0
  SLID_FORMAT        = /\A\d{6}\z/

  # One per level: the sum of article widths on a level cannot exceed sec_width
  Space = Struct.new(:width, :used, keyword_init: true) do
    def free = width - used
  end

  Bin = Struct.new(:section, :level, :space, :depth, :height, keyword_init: true) do
    def ground? = level.lev_num.to_i == GROUND
    def free    = space.free
  end

  Item = Struct.new(:article, :width, :length, :height, :units, :qty, keyword_init: true)

  def self.pad(slid)
    s = slid.to_s.strip
    s.match?(/\A\d{5}\z/) ? "0#{s}" : s
  end

  # Every slid_h of an article, split and padded to 6 digits (10100 → 010100)
  def self.slids(article)
    Array(article["SLID"]).flat_map { |s| s.to_s.split(/[\s,;]+/) }
                          .reject(&:empty?)
                          .map { |s| pad(s) }
  end

  # Aisles 60–80: any location there counts as no location
  def self.no_location_aisle?(num)
    NO_LOCATION.cover?(num)
  end

  def self.plannable_aisle?(aisle)
    num = aisle.aisle_num.to_s.strip
    return false if num.empty? || EXCLUDED_AISLES.include?(num.upcase)
    !no_location_aisle?(num.to_i)
  end

  # Articles with a slid_h of PALLET or 990101 can only be planned in VOSS or PALLET aisles
  def self.reserved_article?(article)
    slids(article).any? { |s| RESERVED_SLIDS.include?(s.upcase) }
  end

  # A section spans several slid section numbers (e.g. section 04 holds 04, 05 and 06),
  # so the slid goes to the highest Sec_num at or below its SS
  def self.section_for(sections, slid)
    ss = slid[2, 2].to_i
    sections.select { |s| s.Sec_num.to_i <= ss }.max_by { |s| s.Sec_num.to_i }
  end

  # The slid's level; a missing level is created
  def self.level_for(section, slid)
    section.levels.to_a.find { |l| l.lev_num.to_i == slid[4, 2].to_i } ||
      section.levels.create!(lev_num: slid[4, 2], lev_depth: section.sec_depth,
                             lev_width: section.sec_width.to_s)
  end

  def self.section_level(sections, slid)
    section = section_for(sections, slid)
    section && [section, level_for(section, slid)]
  end

  # new_slid as typed on the form: trimmed, upper case, 5 digits padded to 6 (10300 → 010300)
  def self.normalize_slid(value)
    pad(value).upcase
  end

  # Manual planning: [section, level] for a new_slid typed on the article form, in ANY aisle.
  #   990100 → the Voss aisle's section, PALLET → the PALLET aisle's section (no level)
  #   AASSLL → aisle AA, section SS, level LL. Aisles can share a number (12 FS, 12 SS):
  #            every one is checked and the slid goes to the closest section.
  def self.manual_location(store, slid)
    aisles = store.aisles.includes(sections: :levels).to_a

    if [VossPlannerService::NEW_SLID, PalletPlannerService::NEW_SLID].include?(slid)
      aisle   = aisles.find { |a| a.aisle_num.to_s.strip.upcase == slid }
      section = aisle&.sections.to_a.min_by { |s| s.Sec_num.to_i }
      return section && [section, nil]
    end

    return nil unless SLID_FORMAT.match?(slid)

    section = aisles.reject { |a| EXCLUDED_AISLES.include?(a.aisle_num.to_s.strip.upcase) }
                    .select { |a| a.aisle_num.to_i == slid[0, 2].to_i }
                    .filter_map { |a| section_for(a.sections.to_a, slid) }
                    .max_by { |s| s.Sec_num.to_i }
    section && [section, level_for(section, slid)]
  end

  def initialize(aisle, hfb: nil, pa: nil, end_date: nil, start_date: nil, max_fcst: nil)
    @aisle      = aisle
    @aisle_no   = aisle.aisle_num.to_i
    @store      = aisle.store
    @hfb        = hfb
    @pa         = pa
    @end_date   = end_date
    @start_date = start_date
    @max_fcst   = max_fcst
  end

  # Returns { candidates:, manual:, in_place:, placed:, no_room:, too_deep:, skipped: }
  def call
    result = { candidates: 0, manual: 0, in_place: 0, placed: 0, no_room: 0, too_deep: 0, skipped: 0 }
    return result unless self.class.plannable_aisle?(@aisle)

    ActiveRecord::Base.transaction do
      @sections    = @aisle.sections.includes(:levels).order(:Sec_num).to_a
      @home_aisles = @store.aisles.select { |x| self.class.plannable_aisle?(x) }
                           .map { |x| x.aisle_num.to_i }.to_set
      reset_previous_plan

      # ---------- STEP 1a: manually planned articles — fixed, NEVER moved, always take space ----------
      manual = Placement.where(mode: MANUAL_MODE, section_id: @sections.map(&:id))
                        .includes(:article).to_a
      result[:manual] = manual.size

      # ---------- STEP 1b: articles already in this aisle (per the CSV) — NEVER moved ----------
      # One placement for EVERY slid_h the article holds in this aisle
      in_place = []
      in_aisle_articles.each do |a|
        aisle_slids(a).each do |slid|
          loc = locate(slid)
          loc ? in_place << [a, slid, loc] : result[:skipped] += 1
        end
      end

      build_bins

      occ_height = Hash.new(0.0)
      manual.each   { |p| occupy(p.article, @bins[p.level_id], occ_height) }
      in_place.each { |a, _slid, (_section, level)| occupy(a, @bins[level.id], occ_height) }
      settle_heights(occ_height)

      in_place.each do |a, slid, (_section, level)|
        bin = @bins[level.id]
        place(a, bin, bin.ground? ? a["PALQ"] : a["MIN"], slid)
        result[:in_place] += 1
      end

      # ---------- STEP 2: fill the remaining sec_width with articles from aisles 60–80 only ----------
      # DT = 1 and heavy articles → level 00; DT = 0 → upper levels
      relocate = relocation_candidates
      result[:candidates] = relocate.size

      ground_items = []
      upper_items  = []
      relocate.each do |a|
        item =
          if heavy?(a) || a["DT"] == 1
            ground_item(a).tap { |i| ground_items << i if i }
          elsif a["DT"] == 0
            upper_item(a).tap { |i| upper_items << i if i }
          end
        result[:skipped] += 1 unless item
      end

      bins = @bins.values
      fill(ground_items, bins.select(&:ground?), result)
      fill(upper_items,  bins.reject(&:ground?), result)
    end

    result
  end

  private

  # ---------- scopes ----------

  # Articles that already have a new_slid are taken (including manual ones) and never planned again
  def eligible(scope)
    scope.where(new_slid: [nil, ""])
  end

  def not_srp4(scope)
    t = Article.arel_table
    scope.where(t[:SRP].eq(nil).or(t[:SRP].not_eq(4)))
  end

  def end_date_ok(scope)
    return scope unless @end_date
    t = Article.arel_table
    scope.where(t[:End_Date_Sale].eq(nil).or(t[:End_Date_Sale].gt(@end_date)))
  end

  # Every article with a CSV slid_h in this aisle, whatever HFB/PA/start date/FCST is selected.
  # Skipped: new_slid already set, SRP = 4, expired (their location is empty).
  def in_aisle_articles
    end_date_ok(not_srp4(eligible(@store.articles)))
      .to_a
      .select { |a| !self.class.reserved_article?(a) && aisle_slids(a).any? }
  end

  # Only articles from aisles 60–80 with no new_slid and no home in a regular aisle
  def relocation_candidates
    t     = Article.arel_table
    scope = end_date_ok(not_srp4(eligible(@store.articles.where(planned: [false, nil]))))
    scope = scope.where(hfb: @hfb) if @hfb
    scope = scope.where(pa: @pa)   if @pa
    scope = scope.where(t[:Start_Date_Sale].eq(nil).or(t[:Start_Date_Sale].lteq(@start_date))) if @start_date
    scope = scope.where(t[:FCST].eq(nil).or(t[:FCST].lteq(@max_fcst))) if @max_fcst

    scope.to_a.select do |a|
      next false if self.class.reserved_article?(a)
      aisles = valid_slids(a).map { |s| s[0, 2].to_i }
      aisles.any? { |n| self.class.no_location_aisle?(n) } &&
        aisles.none? { |n| @home_aisles.include?(n) }
    end
  end

  # Removes this aisle's previous planner placements (manual ones are kept);
  # articles left with no placement get new_slid cleared so they can be planned again
  def reset_previous_plan
    previous = Placement.where(mode: MODE, section_id: @sections.map(&:id))
    ids      = previous.distinct.pluck(:article_id)
    previous.delete_all
    return if ids.empty?

    Article.where(id: ids).where.not(id: Placement.select(:article_id))
           .update_all(planned: false, new_slid: nil)
  end

  # ---------- slid_h (AASSLL) ----------

  def valid_slids(a)
    self.class.slids(a).select { |s| SLID_FORMAT.match?(s) }
  end

  def aisle_slids(a)
    valid_slids(a).select { |s| s[0, 2].to_i == @aisle_no }.uniq
  end

  def locate(slid)
    self.class.section_level(@sections, slid)
  end

  # ---------- bins ----------

  def build_bins
    @bins = {}
    @sections.each do |s|
      s.levels.to_a.sort_by { |l| l.lev_num.to_i }.each do |l|
        @bins[l.id] = Bin.new(section: s, level: l,
                              space: Space.new(width: mm(s.sec_width), used: 0.0),
                              depth: mm(s.sec_depth), height: 0.0)
      end
    end
  end

  # An existing article uses its width on the level and sets the level height
  def occupy(a, bin, occ_height)
    return unless bin
    if bin.ground?
      bin.space.used += ground_w(a)
      occ_height[bin.level.id] = [occ_height[bin.level.id], ground_h(a)].max
    else
      bin.space.used += mm(a["CP_Width"])
      occ_height[bin.level.id] = [occ_height[bin.level.id], mm(a["CP_Height"]) * [a["ASSQ"].to_i, 1].max].max
    end
  end

  # Occupied levels: tallest existing article. Empty upper levels share what is left of sec_height.
  def settle_heights(occ)
    @bins.values.group_by(&:section).each do |section, bins|
      total = mm(section.sec_height)
      total = DEFAULT_SEC_HEIGHT unless total.positive?

      empty = bins.reject(&:ground?).select { |b| occ[b.level.id].zero? }
      share = empty.any? ? [total - bins.sum { |b| occ[b.level.id] }, 0].max / empty.size : 0.0

      bins.each do |b|
        b.height = occ[b.level.id].positive? ? occ[b.level.id] : (b.ground? ? 0.0 : share)
        b.level.update_column(:lev_height, b.height) if b.height.positive?
      end
    end
  end

  # ---------- items ----------

  def ground_item(a)
    w = ground_w(a)
    l = ground_l(a)
    return nil unless w.positive? && l.positive?
    Item.new(article: a, width: w, length: l, height: ground_h(a), units: 1, qty: a["PALQ"])
  end

  def upper_item(a)
    w = mm(a["CP_Width"])
    l = mm(a["CP_Length"])
    h = mm(a["CP_Height"])
    return nil unless [w, l, h].all?(&:positive?)
    Item.new(article: a, width: w, length: l, height: h,
             units: [a["MIN"].to_i, 1].max, qty: a["MIN"])
  end

  # MIN × CP_Height must fit the level height; if not, stack in columns (lower and wider)
  def upper_width(item, bin)
    return nil unless bin.height.positive? && item.height <= bin.height
    return item.width if item.units * item.height <= bin.height

    per_col = (bin.height / item.height).floor
    (item.units.to_f / per_col).ceil * item.width
  end

  # Best fit, widest first: each article goes to the level where it leaves the smallest gap,
  # so every level's sec_width is packed as full as possible
  def fill(items, bins, result)
    items.sort_by { |i| -i.width }.each do |item|
      if bins.any? && bins.none? { |b| item.length <= b.depth }
        result[:too_deep] += 1
        next
      end

      best   = nil
      best_w = nil
      bins.each do |b|
        next if item.length > b.depth
        w = b.ground? ? item.width : upper_width(item, b)
        next unless w && w <= b.free
        if best.nil? || (b.free - w) < (best.free - best_w)
          best   = b
          best_w = w
        end
      end

      if best
        best.space.used += best_w
        place(item.article, best, item.qty)
        result[:placed] += 1
      else
        result[:no_room] += 1
      end
    end
  end

  # Articles with several locations get one placement per location; new_slid keeps the first one
  def place(article, bin, qty, slid = nil)
    slid ||= format("%02d%02d%02d", @aisle_no, bin.section.Sec_num.to_i, bin.level.lev_num.to_i)
    Placement.create!(store: @store, article: article, section_id: bin.section.id,
                      level_id: bin.level.id, mode: MODE, new_slid: slid, quantity: qty)
    article.update_columns(planned: true, new_slid: article.new_slid.presence || slid)
  end

  # ---------- measurements (mm) and weight (g) ----------

  def mm(v) = v.to_s.tr(",", ".").to_f

  # CP_Weight_Gross is stored in kilograms
  def weight_g(a) = mm(a["CP_Weight_Gross"]) * KG_TO_G

  def first_positive(*vals) = vals.find(&:positive?) || 0.0

  def ground_w(a) = first_positive(mm(a["UL_Width_Gross"]),  mm(a["CP_Width"]))
  def ground_l(a) = first_positive(mm(a["UL_Length_Gross"]), mm(a["CP_Length"]))
  def ground_h(a) = first_positive(mm(a["UL_Height_Gross"]), mm(a["CP_Height"]))

  def heavy?(a) = weight_g(a) > HEAVY_WEIGHT_G
end