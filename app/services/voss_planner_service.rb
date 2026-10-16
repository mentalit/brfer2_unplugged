class VossPlannerService
  NEW_SLID   = "990100"
  VOSS_AISLE = "990100"
  MODE       = "voss"

  def self.voss_aisle?(aisle)
    aisle.aisle_num.to_s.strip == VOSS_AISLE
  end

  def initialize(store, section:, hfb:, pa: nil, article_limit: nil, max_height: nil, max_length: nil,
                 max_width: nil, max_weight: nil, max_fcst: nil)
    @store         = store
    @section       = section
    @hfb           = hfb
    @pa            = pa
    @article_limit = article_limit
    @max_fcst      = max_fcst
    @limits = {
      "CP_Height"       => max_height,
      "CP_Length"       => max_length,
      "CP_Width"        => max_width,
      "CP_Weight_Gross" => max_weight
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
          quantity: article["RSSQ"]
        )
        article.update!(planned: true, new_slid: NEW_SLID)
      end

      planned += 1
    end

    planned
  end

  private

  # Unplanned articles in the HFB (and PA if given) with DT = 0 and SRP not 4, highest FCST first
  def candidates
    scope = @store.articles.where(hfb: @hfb, DT: 0, planned: [false, nil])
    scope = scope.where('"articles"."SRP" IS DISTINCT FROM 4')
    scope = scope.where(pa: @pa) if @pa
    scope = scope.where(FCST: ..@max_fcst) if @max_fcst
    scope.order(Article.arel_table[:FCST].desc.nulls_last)
  end

  # Blank limit = no limit. With a limit set, the CP value must exist and be within it.
  def fits?(article)
    @limits.all? do |column, max|
      next true if max.nil?
      value = number(article[column])
      value && value <= max
    end
  end

  def number(value)
    s = value.to_s.strip.tr(",", ".")
    s.empty? ? nil : Float(s, exception: false)
  end
end