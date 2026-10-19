class AislePlannerService
  MODE               = "aisles"
  EXCLUDED_AISLES    = %w[VOSS 990100 PALLET].freeze
  GROUND             = 0
  HEAVY_WEIGHT       = 22679.6
  DEFAULT_SEC_HEIGHT = 2286.0
  SLID_FORMAT        = /\A\d{6}\z/

  Bin = Struct.new(:section, :level, :width, :depth, :height, :used, keyword_init: true) do
    def ground? = level.lev_num.to_i == GROUND
    def free    = width - used
  end

  Item = Struct.new(:article, :width, :length, :height, :units, :qty, :must, keyword_init: true)

  def self.no_location_aisle?(num)
    num > 60 && num < 80
  end

  def self.plannable_aisle?(aisle)
    num = aisle.aisle_num.to_s.strip
    return false if num.empty? || EXCLUDED_AISLES.include?(num.upcase)
    !no_location_aisle?(num.to_i)
  end

  def initialize(aisle, hfb: nil, pa: nil, end_date: nil, start_date: nil)
    @aisle      = aisle
    @aisle_no   = aisle.aisle_num.to_i
    @store      = aisle.store
    @hfb        = hfb
    @pa         = pa
    @end_date   = end_date
    @start_date = start_date
  end

  # Returns { candidates:, in_place:, placed:, no_room:, too_deep:, skipped: }
  def call
    result = { candidates: 0, in_place: 0, placed: 0, no_room: 0, too_deep: 0, skipped: 0 }
    return result unless self.class.plannable_aisle?(@aisle)

    ActiveRecord::Base.transaction do
      @sections = @aisle.sections.includes(:levels).order(:Sec_num).to_a
      reset_previous_plan

      candidates = candidate_scope.to_a
      result[:candidates] = candidates.size

      # Step 1: articles with a slid_h in this aisle stay at their own section/level
      in_place = []
      relocate = []
      candidates.each do |a|
        slid = aisle_slid(a)
        loc  = slid && locate(slid)
        loc ? in_place << [a, slid, loc] : relocate << a
      end

      # Articles physically in this aisle that are not being planned this run still take space
      occupied = occupants(candidates.map(&:id)).filter_map do |a|
        slid = aisle_slid(a)
        loc  = locate(slid)
        loc && [a, slid, loc]
      end

      build_bins

      occ_height = Hash.new(0.0)
      (in_place + occupied).each do |a, _slid, (_section, level)|
        bin = @bins[level.id]
        if bin.ground?
          bin.used += ground_w(a)
          occ_height[level.id] = [occ_height[level.id], ground_h(a)].max
        else
          bin.used += cp(a, "CP_Width")
          occ_height[level.id] = [occ_height[level.id], cp(a, "CP_Height") * [a["ASSQ"].to_i, 1].max].max
        end
      end
      settle_heights(occ_height)

      in_place.each do |a, slid, (_section, level)|
        bin = @bins[level.id]
        place(a, bin, bin.ground? ? a["PALQ"] : a["MIN"], slid)
        result[:in_place] += 1
      end

      # Step 2: fill free space greedily with every other article meeting the criteria
      ground_items = []
      upper_items  = []
      relocate.each do |a|
        must = must_plan?(a)
        item =
          if heavy?(a) || (a["DT"] == 1 && !upper_slid?(a))
            ground_item(a, must).tap { |i| ground_items << i if i }
          elsif a["DT"] == 0 || a["DT"] == 1
            upper_item(a, must).tap { |i| upper_items << i if i }
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

  def not_srp4(scope)
    t = Article.arel_table
    scope.where(t[:SRP].eq(nil).or(t[:SRP].not_eq(4)))
  end

  def end_date_ok(scope)
    return scope unless @end_date
    t = Article.arel_table
    scope.where(t[:End_Date_Sale].eq(nil).or(t[:End_Date_Sale].gt(@end_date)))
  end

  def candidate_scope
    t     = Article.arel_table
    scope = end_date_ok(not_srp4(@store.articles.where(planned: [false, nil])))
    scope = scope.where(hfb: @hfb) if @hfb
    scope = scope.where(pa: @pa)   if @pa
    scope = scope.where(t[:Start_Date_Sale].eq(nil).or(t[:Start_Date_Sale].lteq(@start_date))) if @start_date
    scope
  end

  # SRP = 4 and expired (End_Date_Sale) locations count as empty, so they are not occupants
  def occupants(candidate_ids)
    end_date_ok(not_srp4(@store.articles.where(planned: [false, nil])))
      .where.not(id: candidate_ids)
      .select { |a| aisle_slid(a) }
  end

  def reset_previous_plan
    previous = Placement.where(mode: MODE, section_id: @sections.map(&:id))
    ids      = previous.distinct.pluck(:article_id)
    previous.delete_all
    Article.where(id: ids).where.not(id: Placement.select(:article_id))
           .update_all(planned: false, new_slid: nil)
  end

  # ---------- slid_h (AASSLL) ----------

  def valid_slids(a)
    Array(a["SLID"]).map { |s| s.to_s.strip }.select { |s| SLID_FORMAT.match?(s) }
  end

  def aisle_slid(a)
    valid_slids(a).find { |s| s[0, 2].to_i == @aisle_no }
  end

  def must_plan?(a)
    slids = valid_slids(a)
    slids.empty? || slids.any? { |s| self.class.no_location_aisle?(s[0, 2].to_i) }
  end

  def upper_slid?(a)
    slid = valid_slids(a).first
    slid.present? && slid[4, 2].to_i != GROUND
  end

  def locate(slid)
    section = @sections.find { |s| s.Sec_num.to_i == slid[2, 2].to_i }
    return nil unless section

    level = section.levels.to_a.find { |l| l.lev_num.to_i == slid[4, 2].to_i } ||
            section.levels.create!(lev_num: slid[4, 2], lev_depth: section.sec_depth,
                                   lev_width: section.sec_width.to_s)
    [section, level]
  end

  # ---------- bins ----------

  def build_bins
    @bins = {}
    @sections.each do |s|
      s.levels.to_a.sort_by { |l| l.lev_num.to_i }.each do |l|
        lw = num(l.lev_width)
        @bins[l.id] = Bin.new(section: s, level: l,
                              width: lw.positive? ? lw : num(s.sec_width),
                              depth: depth_mm(s), height: 0.0, used: 0.0)
      end
    end
  end

  # Occupied levels: tallest existing article. Empty upper levels share what is left of sec_height.
  def settle_heights(occ)
    @bins.values.group_by(&:section).each do |section, bins|
      total = num(section.sec_height)
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

  def ground_item(a, must)
    w = ground_w(a)
    l = ground_l(a)
    return nil unless w.positive? && l.positive?
    Item.new(article: a, width: w, length: l, height: ground_h(a), units: 1, qty: a["PALQ"], must: must)
  end

  def upper_item(a, must)
    w = cp(a, "CP_Width")
    l = cp(a, "CP_Length")
    h = cp(a, "CP_Height")
    return nil unless [w, l, h].all?(&:positive?)
    Item.new(article: a, width: w, length: l, height: h,
             units: [a["MIN"].to_i, 1].max, qty: a["MIN"], must: must)
  end

  # MIN × CP_Height must fit the level height; if not, stack in columns (lower and wider)
  def upper_width(item, bin)
    return nil unless bin.height.positive? && item.height <= bin.height
    return item.width if item.units * item.height <= bin.height

    per_col = (bin.height / item.height).floor
    (item.units.to_f / per_col).ceil * item.width
  end

  def fill(items, bins, result)
    items.sort_by { |i| [i.must ? 0 : 1, -i.width] }.each do |item|
      if bins.any? && bins.none? { |b| item.length <= b.depth }
        result[:too_deep] += 1
        next
      end

      placed = bins.any? do |b|
        next false if item.length > b.depth
        w = b.ground? ? item.width : upper_width(item, b)
        next false unless w && w <= b.free

        b.used += w
        place(item.article, b, item.qty)
        true
      end

      placed ? result[:placed] += 1 : result[:no_room] += 1
    end
  end

  def place(article, bin, qty, slid = nil)
    slid ||= format("%02d%02d%02d", @aisle_no, bin.section.Sec_num.to_i, bin.level.lev_num.to_i)
    Placement.create!(store: @store, article: article, section_id: bin.section.id,
                      level_id: bin.level.id, mode: MODE, new_slid: slid, quantity: qty)
    article.update_columns(planned: true, new_slid: slid)
  end

  # ---------- measurements (mm) ----------

  def num(v) = v.to_s.tr(",", ".").to_f

  def cp(a, key) = num(a[key])

  def first_positive(*vals) = vals.find(&:positive?) || 0.0

  def ground_w(a) = first_positive(num(a["UL_Width_Gross"]),  cp(a, "CP_Width"))
  def ground_l(a) = first_positive(num(a["UL_Length_Gross"]), cp(a, "CP_Length"))
  def ground_h(a) = first_positive(num(a["UL_Height_Gross"]), cp(a, "CP_Height"))

  def heavy?(a) = cp(a, "CP_Weight_Gross") > HEAVY_WEIGHT

  # Section depth comes from MAXLENGTH (imported in cm): values under 1000 are converted to mm
  def depth_mm(section)
    d = num(section.sec_depth)
    d.positive? && d < 1000 ? d * 10 : d
  end
end