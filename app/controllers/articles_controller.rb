# article_controller.rb

# article_controller.rb

class ArticlesController < ApplicationController
  before_action :set_article, only: %i[ show edit update destroy ]
  before_action :get_store, only: %i[ new create index totals non_srp_4 search planned_basement ]

  # GET /articles or /articles.json
  def index
    @articles = @store.articles
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


    @planned_basement = @store.articles.where(
  '"SRP" != ? AND "planned" = ? AND EXISTS (
    SELECT 1
    FROM unnest(articles."SLID") AS s(value)
    WHERE s.value ~ \'^[0-9]+$\'
      AND s.value::integer BETWEEN ? AND ?
  )',
  4, true, 580100, 810000
)
  
#     @planned_basement = @store.articles.where(
#   '"SRP" != ? AND EXISTS (
#     SELECT 1
#     FROM unnest(articles."SLID") AS s(value)
#     WHERE s.value ~ \'^[0-9]+$\'
#       AND s.value::integer BETWEEN ? AND ?
#   )',
#   4, 580100, 810000
# )



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
             "MPQ read from: #{r[:mpq_columns]}."

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