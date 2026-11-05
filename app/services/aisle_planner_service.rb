class AislePlannerService
  # All measurements are in mm (articles CP_/UL_, sections, levels, aisles); weights in grams
  MODE               = "aisles"
  MANUAL_MODE        = "manual"
  EXCLUDED_AISLES    = %w[VOSS 990100 PALLET].freeze
  RESERVED_SLIDS     = %w[PALLET 990101].freeze
  NO_LOCATION        = (60..80)
  GROUND             = 0
  HEAVY_WEIGHT_G     = 22679.6
  MULTI_PACK_HEAVY_G = 31751.5  # 70 lb: heavier than this with NO_OF_PACKS >= 2 → never level 00
  LOW_FCST           = 10       # FCST below this ...
  LIGHT_WEIGHT_G     = 11339.8  # ... and lighter than 25 lb → planned like DT = 0 with 2 × FCST
  KG_TO_G            = 1000
  DEFAULT_SEC_HEIGHT = 2286.0

  # Back-to-back aisles (aisle.linked_aisle) share the depth of facing level 00s:
  # section 03-01 faces 05-01. Either side plans as deep as it needs: it gets the pair's total
  # depth minus the deepest article on the other side. No other maximum.
  IKEA_EURO_DEPTH    = 3650.0   # IKEA + EURO pair
  EURO_EURO_DEPTH    = 2690.0   # EURO + EURO pair
  SLID_FORMAT        = /\A\d{6}\z/
  # New articles: no SLID at all, this Start_Date_Sale and one of these DIVs.
  # They are planned like the aisle 60–80 articles.
  NEW_ARTICLE_START  = Date.new(2027, 1, 1)
  NEW_ARTICLE_DIVS   = %w[SF WH].freeze

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
      section.levels.create!(lev_num: slid[4, 2], lev_depth: upper_depth(section),
                             lev_width: section.sec_width.to_s)
  end

  def self.section_level(sections, slid)
    section = section_for(sections, slid)
    section && [section, level_for(section, slid)]
  end

  # Level 00 depth of a section whose aisle is back to back with another aisle:
  #   pair total − deepest article on the facing level 00 (section with the same number).
  # nil when there is no shared depth (not linked, no facing section, no total, or this section or the
  # one behind it is marked "Not linked"); the section's own depth is used then.
  def self.shared_ground_depth(section, aisle = section.aisle)
    partner = aisle.linked_aisle
    return nil unless partner
    return nil if section.unlinked

    total = pair_depth(aisle, partner)
    return nil unless total.positive?

    facing = partner.sections.find { |s| s.Sec_num.to_i == section.Sec_num.to_i }
    return nil if facing.nil? || facing.unlinked

    facing_ground = facing.levels.find { |l| l.lev_num.to_i == GROUND }
    used = facing_ground ? deepest_ground_length(facing_ground) : 0.0
    [total - used, 0.0].max
  end

  # Total depth of a back-to-back pair, front of one aisle to front of the other.
  # IKEA/EURO 3650, EURO/EURO 2690, any other pair: both aisles' MAXLENGTH added together.
  def self.pair_depth(aisle, partner)
    case [rack_type(aisle), rack_type(partner)].sort
    when %w[EURO IKEA] then IKEA_EURO_DEPTH
    when %w[EURO EURO] then EURO_EURO_DEPTH
    else
      num = ->(v) { v.to_s.tr(",", ".").to_f }
      num.(aisle["MAXLENGTH"]) + num.(partner["MAXLENGTH"])
    end
  end

  # Writes the shared level 00 depth into sec_depth of every section of a linked pair
  # (this aisle and the one behind it). Sections with no shared depth ("Not linked", no section behind)
  # get the aisle's own MAXLENGTH. Called after anything is planned or unplanned.
  def self.refresh_shared_depths(aisle)
    return unless aisle

    Aisle.where(id: [aisle.id, aisle.linked_aisle_id].compact).includes(:linked_aisle, sections: :levels).each do |a|
      next unless a.linked_aisle

      own = a["MAXLENGTH"].to_s.tr(",", ".").to_f
      a.sections.each do |s|
        depth = shared_ground_depth(s, a) || (own if own.positive?)
        s.update_column(:sec_depth, depth) if depth
      end
    end
  end

  # An aisle that is no longer linked: sec_depth back to the aisle's own MAXLENGTH
  def self.reset_depths(aisle)
    return unless aisle && aisle["MAXLENGTH"].to_f.positive?
    aisle.sections.update_all(sec_depth: aisle["MAXLENGTH"])
  end

  # Depth of the levels above 00. In a linked aisle sec_depth holds the shared level 00 depth,
  # so the upper levels use the aisle's own MAXLENGTH.
  def self.upper_depth(section, aisle = section.aisle)
    own = aisle["MAXLENGTH"].to_s.tr(",", ".").to_f
    aisle.linked_aisle_id && own.positive? ? own : section.sec_depth.to_s.tr(",", ".").to_f
  end

  # Deepest article placed on a level 00 (UL length, CP length when UL is missing)
  def self.deepest_ground_length(level)
    Placement.where(level_id: level.id).includes(:article)
             .map { |p| ground_length(p.article) }.max || 0.0
  end

  def self.ground_length(article)
    num = ->(v) { v.to_s.tr(",", ".").to_f }
    [num.(article["UL_Length_Gross"]), num.(article["CP_Length"])].find(&:positive?) || 0.0
  end

  # "IKEA" / "EURO"
  def self.rack_type(aisle)
    aisle["RACKTYPE"].to_s.strip.upcase
  end

  # new_slid as typed on the form: trimmed, upper case, 5 digits padded to 6 (10300 → 010300)
  def self.normalize_slid(value)
    pad(value).upcase
  end

  # Manual planning: [section, level] for a new_slid typed on the article form, in ANY aisle.
  #   990100 → the Voss aisle's section, PALLET → the PALLET aisle's section (no level)
  #   AASSLL → aisle AA, section SS, level LL. Aisles can share a number (12 FS, 12 SS):
  #            every one is checked and the slid goes to the closest section.
  # (pass aisles: when looking up many slids, so the aisles are only loaded once)
  def self.manual_location(store, slid, aisles: nil)
    aisles ||= store.aisles.includes(sections: :levels).to_a

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

  # Manual planning: what doesn't fit at a manual placement (empty = it fits).
  # Only a warning — the manual placement always stays. Voss / PALLET have no space limits.
  # Same measurements the planner uses: level 00 = UL (CP if missing), upper levels = CP,
  # height on upper levels = CP_Height × ASSQ.
  def self.manual_fit_problems(placement)
    level = placement.level
    return [] unless level

    section = placement.section
    article = placement.article
    ground  = level.lev_num.to_i == GROUND
    num     = ->(v) { v.to_s.tr(",", ".").to_f }
    first   = ->(*vals) { vals.find(&:positive?) || 0.0 }
    mm      = ->(v) { "#{v.round} mm" }
    width   = ->(a) { ground ? first.(num.(a["UL_Width_Gross"]), num.(a["CP_Width"])) : num.(a["CP_Width"]) }

    problems = []

    # Width: everything else already on this level + this article must fit sec_width
    used = Placement.where(level_id: level.id).where.not(id: placement.id)
                    .includes(:article).sum { |p| width.(p.article) }
    free = num.(section.sec_width) - used
    w    = width.(article)
    if w > free
      problems << "#{mm.(w - free)} over the level's free width (article #{mm.(w)} wide, #{mm.([free, 0].max)} free)"
    end

    # Depth (level 00 of a back-to-back aisle: the depth the facing level 00 leaves)
    length = ground ? first.(num.(article["UL_Length_Gross"]), num.(article["CP_Length"])) : num.(article["CP_Length"])
    depth  = ground ? (shared_ground_depth(section) || num.(section.sec_depth)) : upper_depth(section)
    if depth.positive? && length > depth
      problems << "#{mm.(length - depth)} too deep (article #{mm.(length)}, section #{mm.(depth)})"
    end

    # Height
    height = if ground
               first.(num.(article["UL_Height_Gross"]), num.(article["CP_Height"]))
             else
               num.(article["CP_Height"]) * [article["ASSQ"].to_i, 1].max
             end
    sec_h = num.(section.sec_height)
    sec_h = DEFAULT_SEC_HEIGHT unless sec_h.positive?
    if height > sec_h
      problems << "#{mm.(height - sec_h)} too tall (article #{mm.(height)}, section #{mm.(sec_h)})"
    end

    problems
  end

  def initialize(aisle, hfb: nil, pa: nil, end_date: nil, start_date: nil, max_fcst: nil,
                 ignore_weight: false)
    @aisle      = aisle
    @aisle_no   = aisle.aisle_num.to_i
    @store      = aisle.store
    @hfb        = hfb
    @pa         = pa
    @end_date   = end_date
    @start_date = start_date
    @max_fcst   = max_fcst
    # true = the 22679.6 g rule is off: heavy articles go by DT like any other article
    @ignore_weight = ignore_weight
  end

  # Each planning ADDS to the previous ones: nothing already placed in the aisle is removed or moved.
  # (Unplan aisle is the way to start the aisle again from empty.)
  # Returns { candidates:, manual:, kept:, in_place:, placed:, no_room:, too_deep:, skipped: }
  def call
    result = { candidates: 0, manual: 0, kept: 0, in_place: 0, placed: 0, no_room: 0, too_deep: 0, skipped: 0 }
    return result unless self.class.plannable_aisle?(@aisle)

    ActiveRecord::Base.transaction do
      @sections    = @aisle.sections.includes(:levels).order(:Sec_num).to_a
      @home_aisles = @store.aisles.select { |x| self.class.plannable_aisle?(x) }
                           .map { |x| x.aisle_num.to_i }.to_set

      # ---------- STEP 1a: everything already placed in this aisle — kept, NEVER moved, always takes space ----------
      # Manual placements and every earlier Aisles planning (and the upload's placements)
      existing = Placement.where(mode: [MANUAL_MODE, MODE], section_id: @sections.map(&:id))
                          .includes(:article, :level).to_a
      result[:manual] = existing.count { |p| p.mode == MANUAL_MODE }
      result[:kept]   = existing.count { |p| p.mode == MODE }

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
      existing.each { |p| occupy_existing(p, occ_height) }
      in_place.each { |a, _slid, (_section, level)| occupy(a, @bins[level.id], occ_height) }
      settle_heights(occ_height)

      in_place.each do |a, slid, (_section, level)|
        bin = @bins[level.id]
        place(a, bin, bin.ground? ? a["PALQ"] : a["MIN"], slid)
        result[:in_place] += 1
      end

      # ---------- STEP 2: fill the remaining sec_width with articles from aisles 60–80
      # and new articles (no SLID, Start_Date_Sale 01/01/2027, DIV SF or WH) ----------
      # FCST < 10 and under 25 lb → upper levels like DT = 0, space for 2 × FCST (whatever its DT)
      # DT = 0, under 22679.6 g and NO_OF_PACKS >= 2 → upper levels only, never level 00
      # Over 31751.5 g (70 lb) and NO_OF_PACKS >= 2 → upper levels only, never level 00 (any DT)
      # DT = 1 and heavy articles → level 00; DT = 0 → upper levels
      relocate = relocation_candidates
      result[:candidates] = relocate.size

      ground_items = []
      upper_items  = []
      relocate.each do |a|
        item =
          if low_runner?(a)
            upper_item(a, units: (2 * a["FCST"].to_f).ceil).tap { |i| upper_items << i if i }
          elsif multi_pack_upper_only?(a) || heavy_multi_pack?(a)
            upper_item(a).tap { |i| upper_items << i if i }
          elsif heavy?(a) || a["DT"] == 1
            ground_item(a).tap { |i| ground_items << i if i }
          elsif a["DT"] == 0
            upper_item(a).tap { |i| upper_items << i if i }
          end
        result[:skipped] += 1 unless item
      end

      bins = @bins.values
      # Back-to-back aisle: level 00 is filled by depth (longest articles where the other side is shallowest)
      if @aisle.linked_aisle
        fill_by_depth(ground_items, bins.select(&:ground?), result)
      else
        fill(ground_items, bins.select(&:ground?), result)
      end
      fill(upper_items,  bins.reject(&:ground?), result)

      # Back-to-back aisles: sec_depth of both sides = the depth each side has left
      self.class.refresh_shared_depths(@aisle)
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

  # Articles with no new_slid and either:
  #   - a slid_h only in aisles 60–80 (no home in a regular aisle), or
  #   - a new article: no SLID at all, Start_Date_Sale 01/01/2027, DIV SF or WH
  def relocation_candidates
    t     = Article.arel_table
    scope = end_date_ok(not_srp4(eligible(@store.articles.where(planned: [false, nil]))))
    scope = scope.where(hfb: @hfb) if @hfb
    scope = scope.where(pa: @pa)   if @pa
    # Start Date Sale filter: blank, on/before the date, or a new article (NEW_ARTICLE_START)
    scope = scope.where(t[:Start_Date_Sale].eq(nil)
                         .or(t[:Start_Date_Sale].lteq(@start_date))
                         .or(t[:Start_Date_Sale].eq(NEW_ARTICLE_START))) if @start_date
    scope = scope.where(t[:FCST].eq(nil).or(t[:FCST].lteq(@max_fcst))) if @max_fcst

    scope.to_a.select do |a|
      next false if self.class.reserved_article?(a)
      next true  if new_article?(a)

      aisles = valid_slids(a).map { |s| s[0, 2].to_i }
      aisles.any? { |n| self.class.no_location_aisle?(n) } &&
        aisles.none? { |n| @home_aisles.include?(n) }
    end
  end

  # No SLID (nil, empty or blank), Start_Date_Sale = NEW_ARTICLE_START and DIV SF or WH
  def new_article?(a)
    self.class.slids(a).empty? &&
      a["Start_Date_Sale"] == NEW_ARTICLE_START &&
      NEW_ARTICLE_DIVS.include?(a["DIV"].to_s.strip.upcase)
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

  # Level 00 of a back-to-back aisle gets the depth the facing level 00 leaves;
  # upper levels of a linked aisle use the aisle's MAXLENGTH, otherwise the section's depth
  def build_bins
    @bins = {}
    @sections.each do |s|
      s.levels.to_a.sort_by { |l| l.lev_num.to_i }.each do |l|
        depth = if l.lev_num.to_i == GROUND
                  self.class.shared_ground_depth(s, @aisle) || mm(s.sec_depth)
                else
                  self.class.upper_depth(s, @aisle)
                end

        @bins[l.id] = Bin.new(section: s, level: l,
                              space: Space.new(width: mm(s.sec_width), used: 0.0),
                              depth: depth, height: 0.0)
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

  # A placement that is already in the aisle takes its space again.
  # Articles an earlier planning put on an upper level away from their own slid_h may have been
  # stacked in several columns (MIN × CP_Height taller than the level), so they take
  # CP_Width × columns, and the level keeps the height it was planned with.
  def occupy_existing(p, occ_height)
    bin = @bins[p.level_id]
    return unless bin

    planned_here = p.mode == MODE && !bin.ground? && !self.class.slids(p.article).include?(p.new_slid)
    return occupy(p.article, bin, occ_height) unless planned_here

    a       = p.article
    w       = mm(a["CP_Width"])
    h       = mm(a["CP_Height"])
    lev_h   = p.level.lev_height.to_f
    columns = 1
    if h.positive? && lev_h.positive?
      per_col = [(lev_h / h).floor, 1].max
      columns = ([p.quantity.to_i, 1].max.to_f / per_col).ceil
    end

    bin.space.used += w * columns
    occ_height[bin.level.id] = [occ_height[bin.level.id], lev_h.positive? ? lev_h : h].max
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

  # Upper levels use CP measurements. Space is for MIN units, or for the given units
  # (2 × FCST for low runners), which are then also the planned quantity.
  def upper_item(a, units: nil)
    w = mm(a["CP_Width"])
    l = mm(a["CP_Length"])
    h = mm(a["CP_Height"])
    return nil unless [w, l, h].all?(&:positive?)

    qty = units || a["MIN"]
    Item.new(article: a, width: w, length: l, height: h,
             units: [qty.to_i, 1].max, qty: qty)
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

  # Level 00 of a back-to-back aisle. Each level 00's depth = what the facing level 00 leaves,
  # so the deepest bin is the one facing the shallowest article in the linked aisle.
  # Sections are filled from the deepest bin down, each with the longest articles that still fit
  # (depth and free width), so long articles go where the other side leaves the most room.
  def fill_by_depth(items, bins, result)
    max_depth = bins.map(&:depth).max || 0.0
    remaining = items.sort_by { |i| [-i.length, -i.width] }

    too_deep, remaining = remaining.partition { |i| bins.any? && i.length > max_depth }
    result[:too_deep] += too_deep.size

    bins.sort_by { |b| -b.depth }.each do |bin|
      placed = []
      remaining.each do |item|
        next if item.length > bin.depth || item.width > bin.free
        bin.space.used += item.width
        place(item.article, bin, item.qty)
        result[:placed] += 1
        placed << item
      end
      remaining -= placed
    end

    result[:no_room] += remaining.size
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

  def heavy?(a) = !@ignore_weight && weight_g(a) > HEAVY_WEIGHT_G

  # DT = 0, lighter than 22679.6 g and 2 or more packs → can never go on level 00
  def multi_pack_upper_only?(a)
    a["DT"] == 0 && a["NO_OF_PACKS"].to_i >= 2 && weight_g(a) < HEAVY_WEIGHT_G
  end

  # Heavier than 31751.5 g (70 lb) and 2 or more packs → can never go on level 00, whatever its DT
  def heavy_multi_pack?(a)
    a["NO_OF_PACKS"].to_i >= 2 && weight_g(a) > MULTI_PACK_HEAVY_G
  end

  # FCST below 10 and a known weight under 25 lb
  def low_runner?(a)
    fcst = a["FCST"]
    w    = weight_g(a)
    !fcst.nil? && fcst.to_f < LOW_FCST && w.positive? && w < LIGHT_WEIGHT_G
  end
end