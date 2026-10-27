class VossPlannerService
  NEW_SLID   = "990100"
  VOSS_AISLE = "990100"
  MODE       = "voss"

  # CP_Weight_Gross is stored in kg; the Weight limit is entered in g
  KG_TO_G = 1000

  # FCST below 10 and lighter than 25 lb → quantity 2 × FCST instead of RSSQ (same rule as the Aisle planner)
  LOW_FCST       = 10
  LIGHT_WEIGHT_G = 11339.8

  def self.voss_aisle?(aisle)
    aisle.aisle_num.to_s.strip == VOSS_AISLE
  end

  def initialize(store, section:, hfb:, pa: nil, article_limit: nil, max_height: nil, max_length: nil,
                 max_width: nil, max_weight: nil, max_fcst: nil, exclude_names: nil, dt_one_only: false)
    @store         = store
    @section       = section
    @hfb           = hfb
    @pa            = pa
    @article_limit = article_limit
    @max_fcst      = max_fcst
    @max_weight_g  = max_weight
    # "SKOGSTA, LACK" → ["SKOGSTA", "LACK"]; any article whose name contains one is skipped
    @exclude_names = exclude_names.to_s.split(",").map(&:strip).reject(&:empty?)
    # true = plan ONLY DT = 1 articles; false = the normal DT = 0 articles
    @dt            = dt_one_only ? 1 : 0
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
      next unless fits?(article)

      Article.transaction do
        Placement.create!(
          store:    @store,
          article:  article,
          section:  @section,
          mode:     MODE,
          new_slid: NEW_SLID,
          quantity: quantity(article)
        )
        article.update!(planned: true, new_slid: NEW_SLID)
      end

      planned += 1
    end

    planned
  end

  private

  # Unplanned articles in the HFB (and PA if given) with DT = 0 (or DT = 1 when "Only DT = 1" is ticked)
  # and SRP not 4, highest FCST first.
  # Articles whose name contains an excluded name (not case sensitive) are never planned.
  def candidates
    scope = @store.articles.where(hfb: @hfb, DT: @dt, planned: [false, nil])
    scope = scope.where('"articles"."SRP" IS DISTINCT FROM 4')
    scope = scope.where(pa: @pa) if @pa
    scope = scope.where(FCST: ..@max_fcst) if @max_fcst
    @exclude_names.each do |name|
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(name)}%"
      scope = scope.where('"articles"."ARTNAME_UNICODE" IS NULL OR "articles"."ARTNAME_UNICODE" NOT ILIKE ?', pattern)
    end
    scope.order(Article.arel_table[:FCST].desc.nulls_last)
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

  # 2 × FCST (rounded up) for light articles with FCST below 10, otherwise RSSQ
  def quantity(article)
    fcst = article["FCST"]
    kg   = number(article["CP_Weight_Gross"])
    if !fcst.nil? && fcst.to_f < LOW_FCST && kg && kg.positive? && (kg * KG_TO_G) < LIGHT_WEIGHT_G
      (2 * fcst.to_f).ceil
    else
      article["RSSQ"]
    end
  end

  def number(value)
    s = value.to_s.strip.tr(",", ".")
    s.empty? ? nil : Float(s, exception: false)
  end
end