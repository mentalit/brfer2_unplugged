class ArticlesController < ApplicationController
  before_action :set_article, only: %i[ show edit update destroy ]
  before_action :get_store, only: %i[ new create index ]

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

      def import
    store = Store.find(params[:store_id])

    if params[:article_file].blank? && params[:item_file].blank?
      redirect_to store_articles_path(store), alert: "Please choose the CSV files to upload."
      return
    end

    r = ArticleUploadService.new(
      store,
      article_file: params[:article_file],
      item_file: params[:item_file]
    ).call

    missing = r[:missing_mpq_artnos]
    missing_text = missing.any? ? " (#{missing.first(20).join(', ')}#{missing.size > 20 ? ', …' : ''})" : ""

    notice = "Created #{r[:created]}, updated #{r[:updated]}, unchanged #{r[:unchanged]}. " \
             "Skipped: #{r[:skipped_division]} division, #{r[:skipped_expired_no_stock]} expired/no stock, " \
             "#{r[:skipped_future]} future, #{r[:skipped_no_artno]} no ARTNO. " \
             "No MPQ: #{r[:missing_mpq]}#{missing_text}. " \
             "Failed: #{r[:failed]} (MPQ still written: #{r[:mpq_forced]}). " \
             "Next start date: #{r[:next_start_date]&.strftime('%m/%d/%y') || 'none'}. " \
             "DWP file found: #{r[:item_file]}, matched #{r[:dwp_matched]} of #{r[:articles_total]} articles. " \
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
  def update
    respond_to do |format|
      if @article.update(article_params)
        format.html { redirect_to @article, notice: "Article was successfully updated.", status: :see_other }
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
    # Use callbacks to share common setup or constraints between actions.
    def set_article
      @article = Article.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def article_params
      params.expect(article: [ :hfb, :pa, :ARTNO, :ARTNAME_UNICODE, :SLID, :DIV, :ASSQ, :SSQ, :DTFP, :DTFP_PLUS, :MIN, :MAX, :RSSQ, :SRP, :DT, :PALQ, :MPQ, :Item_No, :CP_Sale_Sol_Name, :CP_Length, :CP_Width, :CP_Height, :CP_Weight_Gross, :UL_Sale_Sol_Name, :UL_Length_Gross, :UL_Width_Gross, :UL_Height_Gross, :planned, :new_slid, :Start_Date_Sale, :End_Date_Sale, :FCST, :AVAILSTOCK, :linked_families, :store_id ])
    end
end
