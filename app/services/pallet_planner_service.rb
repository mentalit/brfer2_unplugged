class PalletPlannerService
  NEW_SLID     = "PALLET"
  PALLET_AISLE = "PALLET"
  MODE         = "pallet"

  # CP_Weight_Gross is stored in kg; the Weight limit is entered in g
  KG_TO_G = 1000

  # Articles must currently be located in this SLID range...
  SLID_RANGE = 590000..800000
  # ...or have no SLID and start selling on this date
  NEW_ARTICLE_START_DATE = Date.new(2027, 1, 1)

  def self.pallet_aisle?(aisle)
    aisle.aisle_num.to_s.strip.upcase == PALLET_AISLE
  end

  def initialize(store, section:, hfb:, pa: nil, article_limit: nil, max_height: nil, max_length: nil,
                 max_width: nil, max_weight: nil, max_fcst: nil, max_palq: nil)
    @store         = store
    @section       = section
    @hfb           = hfb
    @pa            = pa
    @article_limit = article_limit
    @max_fcst      = max_fcst
    @max_palq      = max_palq
    @max_weight_g  = max_weight
    @limits = {
      "CP_Height" => max_height,  # mm
      "CP_Length" => max_length,  # mm
      "CP_Width"  => max_width    # mm
    }
  end

  # Returns the number of articles planned
  def call
    planned = 0

    candidates.each do |article|
      break if @article_limit && planned >= @article_limit
      next unless location_ok?(article)
      next unless fits?(article)

      Article.transaction do
        Placement.create!(
          store:    @store,
          article:  article,
          section:  @section,
          mode:     MODE,
          new_slid: NEW_SLID,
          quantity: article["PALQ"]
        )
        article.update!(planned: true, new_slid: NEW_SLID)
      end

      planned += 1
    end

    planned
  end

  private

  # Unplanned articles in the HFB (and PA if given) with DT = 1, SRP not 4,
  # and PALQ above 0 and within the PALQ limit, highest FCST first
  def candidates
    scope = @store.articles.where(hfb: @hfb, DT: 1, planned: [false, nil])
    scope = scope.where('"articles"."SRP" IS DISTINCT FROM 4')
    scope = scope.where('"articles"."PALQ" > 0')
    scope = scope.where(PALQ: ..@max_palq) if @max_palq
    scope = scope.where(pa: @pa) if @pa
    scope = scope.where(FCST: ..@max_fcst) if @max_fcst
    scope.order(Article.arel_table[:FCST].desc.nulls_last)
  end

  # Any SLID between 590000 and 800000, or no SLID and Start_Date_Sale = 01/01/27
  def location_ok?(article)
    slids = slids_for(article)

    if slids.empty?
      start_date(article) == NEW_ARTICLE_START_DATE
    else
      slids.any? { |s| s.match?(/\A\d+\z/) && SLID_RANGE.cover?(s.to_i) }
    end
  end

  # Every SLID of an article, split on spaces, commas or semicolons
  def slids_for(article)
    Array(article["SLID"]).flat_map { |s| s.to_s.split(/[\s,;]+/) }.reject(&:empty?)
  end

  def start_date(article)
    value = article["Start_Date_Sale"]
    return nil if value.nil?
    return value.to_date if value.is_a?(Date) || value.is_a?(Time)

    s = value.to_s.strip
    return nil if s.empty?

    ["%m/%d/%y", "%m/%d/%Y", "%Y-%m-%d"].each do |format|
      begin
        return Date.strptime(s, format)
      rescue ArgumentError
        next
      end
    end

    nil
  end

  # Blank limit = no limit. With a limit set, the CP value must exist and be within it.
  def fits?(article)
    dims_ok = @limits.all? do |column, max|
      next true if max.nil?
      value = number(article[column])
      value && value <= max
    end

    dims_ok && weight_ok?(article)
  end

  def weight_ok?(article)
    return true if @max_weight_g.nil?
    kg = number(article["CP_Weight_Gross"])
    kg && (kg * KG_TO_G) <= @max_weight_g
  end

  def number(value)
    s = value.to_s.strip.tr(",", ".")
    s.empty? ? nil : Float(s, exception: false)
  end
end