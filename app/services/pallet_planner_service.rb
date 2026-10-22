class PalletPlannerService
  NEW_SLID     = "PALLET"
  PALLET_AISLE = "PALLET"
  MODE         = "pallet"

  # CP_Weight_Gross is stored in kg; the Weight limit is entered in g
  KG_TO_G = 1000

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