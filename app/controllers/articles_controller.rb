class ArticlesController < ApplicationController
  before_action :set_article, only: %i[ show edit update destroy ]
  before_action :get_store, only: %i[ new create index totals non_srp_4 search planned_basement unplanned_by_hfb less_than_1 ]

  # A slid_h between two numbers (e.g. the basement, 580100–810000)
  SLID_RANGE_SQL = 'EXISTS (
    SELECT 1
    FROM unnest(articles."SLID") AS s(value)
    WHERE s.value ~ \'^[0-9]+$\'
      AND s.value::integer BETWEEN ? AND ?
  )'.freeze

  # New articles: no SLID at all (nil, {} or only blanks), a given Start_Date_Sale, and DIV SF, WH or blank
  NEW_ARTICLE_SQL = '"Start_Date_Sale" = ? AND upper(coalesce(btrim("DIV"), \'\')) IN (\'SF\', \'WH\', \'\') AND NOT EXISTS (
    SELECT 1
    FROM unnest(articles."SLID") AS s(value)
    WHERE btrim(s.value) <> \'\'
  )'.freeze

  # GET /articles or /articles.json
  def index
    @articles = @store.articles
  end

    def less_than_1
    @less_than_1 = @store.articles
      .where(planned: true)
      .where(FCST: ..1)
      .where('"articles"."new_slid" IS NULL OR TRIM("articles"."new_slid") NOT IN (?)', %w[990100 PALLET])
      .order(:hfb, :pa, :ARTNO)

    @less_than_1_count = @less_than_1.count
  end

  # GET /articles/1 or /articles/1.json
  def show
  end

  # GET /articles/new
  def new
    @article = @store.articles.build
  end

  # GET /articles/1/edit
  def edit
  end

  def search
    @query = params[:q].to_s.strip

    if @query.blank?
      redirect_to store_articles_path(@store), alert: "Enter an article number or name to search."
      return
    end

    digits = @query.gsub(/[^0-9A-Za-z]/, "")

    @results = @store.articles
      .where(
        %(REPLACE(CAST("ARTNO" AS TEXT), '.', '') ILIKE :digits OR "ARTNAME_UNICODE" ILIKE :name),
        digits: "%#{digits}%",
        name: "%#{@query}%"
      )
      .order(:ARTNO)
      .limit(100)

    exact = @results.find { |a| a.ARTNO.to_s.delete(".") == digits }

    if exact
      redirect_to article_path(exact)
    elsif @results.size == 1
      redirect_to article_path(@results.first)
    end
  end

  def totals
    @total_article_count = @store.articles.where.not(SRP: 4).count

    @planned_articles = @store.articles.where(planned: true)

    @srp_4_articles = @store.articles.where(SRP: 4).sort_by { |x| x.ARTNO }

    @unplanned = @store.articles
      .where.not(planned: true)
      .where.not(SRP: 4)
      .where('"End_Date_Sale" > ? OR "End_Date_Sale" IS NULL', Date.today)
  end

  def non_srp_4
    @non_srp_4 = @store.articles
                       .where(SRP: 4)
                       .where('? = ANY("SLID")', "990101")
  end

  def planned_basement
    new_start = AislePlannerService::NEW_ARTICLE_START

    # Basement slid_h, or a new article (Start_Date_Sale = NEW_ARTICLE_START, no SLID)
    basement = @store.articles.where("(#{SLID_RANGE_SQL}) OR (#{NEW_ARTICLE_SQL})", 580100, 810000, new_start)

    # Not SRP 4; a blank SRP is not SRP 4, so it stays in
    @unplanned_basement = basement.where('"SRP" IS DISTINCT FROM 4')

    @planned_basement = @unplanned_basement.where(planned: true)

    @unplanned_basement_srp_1 = basement.where(SRP: 1, planned: [false, nil])

    # The new articles on their own
    new_articles       = @unplanned_basement.where(NEW_ARTICLE_SQL, new_start)
    @new_planned       = new_articles.where(planned: true).count
    @new_unplanned     = new_articles.where(planned: [false, nil]).count
    @new_article_start = new_start

    counts = [
      Arel.sql('COUNT(*) FILTER (WHERE "planned" = true)'),
      Arel.sql('COUNT(*) FILTER (WHERE "planned" IS NOT TRUE)'),
      Arel.sql('COUNT(*)')
    ]

    @basement_by_hfb = @unplanned_basement.group(:hfb).order(:hfb).pluck(:hfb, *counts)
    @basement_by_pa  = @unplanned_basement.group(:pa).order(:pa).pluck(:pa, *counts)
  end

  def remove
    store = Store.find(params[:store_id])

    if params[:remove_file].blank?
      redirect_to store_articles_path(store), alert: "Please choose the CSV of articles to delete."
      return
    end

    r  = ArticleRemovalService.new(store, params[:remove_file]).call
    nf = r[:not_found]

    notice = "Deleted #{r[:deleted]} of #{r[:requested]} articles and #{r[:placements_deleted]} placements. " \
             "#{r[:freed_slids]} locations are now free for planning."
    notice += " Not found: #{nf.first(20).join(', ')}#{nf.size > 20 ? ', …' : ''}" if nf.any?

    redirect_to store_articles_path(store), notice: notice
  rescue ArticleRemovalService::UploadError, CSV::MalformedCSVError => e
    Rails.logger.error "[ArticleRemoval] STOPPED: #{e.message}"
    redirect_to store_articles_path(store), alert: e.message
  end

  def unplanned_by_hfb
    cutoff    = Date.new(2026, 10, 2)
    new_start = AislePlannerService::NEW_ARTICLE_START

    # SRP 4 is never listed as unplanned; a blank SRP is not SRP 4, so it stays in.
    # Basement slid_h before the cutoff, or a new article (Start_Date_Sale = NEW_ARTICLE_START, no SLID)
    scope = @store.articles
      .where(planned: [false, nil])
      .where('"SRP" IS DISTINCT FROM 4')
      .where('"Start_Date_Sale" < ? OR "Start_Date_Sale" IS NULL OR "Start_Date_Sale" = ?', cutoff, new_start)
      .where("(#{SLID_RANGE_SQL}) OR (#{NEW_ARTICLE_SQL})", 590000, 819999, new_start)

    @unplanned_count   = scope.count
    @new_count         = scope.where(NEW_ARTICLE_SQL, new_start).count
    @new_article_start = new_start
    @unplanned_by_hfb  = scope.order(:hfb, :ARTNO).group_by(&:hfb)
  end

  def import
    store = Store.find(params[:store_id])

    if params[:article_file].blank? && params[:item_file].blank?
      redirect_to store_articles_path(store), alert: "Please choose the CSV files to upload."
      return
    end

    r = ArticleUploadService.new(
      store,
      article_file: params[:article_file],
      item_file: params[:item_file],
      slm0002_file: params[:slm0002_file],
      al010_file: params[:al010_file]
    ).call

    missing = r[:missing_mpq_artnos]
    missing_text = missing.any? ? " (#{missing.first(20).join(', ')}#{missing.size > 20 ? ', …' : ''})" : ""

    blank_div      = r[:div_blank_artnos]
    blank_div_text = blank_div.any? ? " (#{blank_div.first(20).join(', ')}#{blank_div.size > 20 ? ', …' : ''})" : ""

    notice = "Created #{r[:created]}, updated #{r[:updated]}, unchanged #{r[:unchanged]}. " \
             "Pre-planned at slid_h: #{r[:pre_planned]}. " \
             "Placements created: #{r[:placements_created]} (no matching level: #{r[:placements_no_level]}). " \
             "Skipped: #{r[:skipped_division]} division, #{r[:skipped_expired_no_stock]} expired/no stock, " \
             "#{r[:skipped_future]} future, #{r[:skipped_no_artno]} no ARTNO. " \
             "No MPQ: #{r[:missing_mpq]}#{missing_text}. " \
             "Failed: #{r[:failed]} (MPQ still written: #{r[:mpq_forced]}). " \
             "Next start date: #{r[:next_start_date]&.strftime('%m/%d/%y') || 'none'}. " \
             "DWP file found: #{r[:item_file]}, matched #{r[:dwp_matched]} of #{r[:articles_total]} articles. " \
             "SLM0002 matched: #{r[:slm0002_matched]}. Al010 matched: #{r[:al010_matched]}. " \
             "MPQ read from: #{r[:mpq_columns]}. " \
             "DT from Al010 Del Type: #{r[:dt_from_al010]}. " \
             "DIV from Al010 Sales Method: #{r[:div_from_al010]}. Blank DIV: #{r[:div_blank]}#{blank_div_text}. " \
             "MIN from MPQ: #{r[:min_from_mpq]} (#{r[:min_from_al010]} from Al010)."

    redirect_to store_articles_path(store), notice: notice
  rescue ArticleUploadService::UploadError, CSV::MalformedCSVError => e
    redirect_to store_articles_path(store), alert: e.message
  end

  # POST /articles or /articles.json
  def create
    @article = @store.articles.build(article_params)

    respond_to do |format|
      if @article.save
        format.html { redirect_to @article, notice: "Article was successfully created." }
        format.json { render :show, status: :created, location: @article }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @article.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /articles/1 or /articles/1.json
  # Editing new_slid here = manual planning: the article is placed at that location, always
  def update
    @article.manual_planning = true

    respond_to do |format|
      if @article.update(article_params)
        notice = "Article was successfully updated."
        notice += " Manually planned at #{@article.new_slid}." if @article.placements.exists?(mode: AislePlannerService::MANUAL_MODE)
        format.html { redirect_to @article, notice: notice, status: :see_other }
        format.json { render :show, status: :ok, location: @article }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @article.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /articles/1 or /articles/1.json
  def destroy
    @article.destroy!

    respond_to do |format|
      format.html { redirect_to articles_path, notice: "Article was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    def set_article
      @article = Article.find(params.expect(:id))
    end

    def article_params
      permitted = params.expect(article: [ :hfb, :pa, :ARTNO, :ARTNAME_UNICODE, :SLID, :DIV, :ASSQ, :SSQ, :DTFP, :DTFP_PLUS, :MIN, :MAX, :RSSQ, :SRP, :DT, :PALQ, :MPQ, :Item_No, :CP_Sale_Sol_Name, :CP_Length, :CP_Width, :CP_Height, :CP_Weight_Gross, :UL_Sale_Sol_Name, :UL_Length_Gross, :UL_Width_Gross, :UL_Height_Gross, :planned, :new_slid, :Start_Date_Sale, :End_Date_Sale, :FCST, :AVAILSTOCK, :linked_families, :store_id ])

      # SLID is typed as "010100, 010200" → ["010100", "010200"]
      if permitted.key?(:SLID)
        permitted[:SLID] = permitted[:SLID].to_s.split(/[\s,;{}"]+/).reject(&:blank?).uniq
      end

      permitted
    end
end