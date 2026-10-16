require "csv"

class SectionsController < ApplicationController
  before_action :set_section, only: %i[ show edit update destroy ]
  before_action :get_aisle, only: %i[ new create index plan_voss export_voss ]

  # GET /sections or /sections.json
  def index
    @sections   = @aisle.sections
    @voss_aisle = VossPlannerService.voss_aisle?(@aisle)
    store       = @aisle.store

    @hfb  = params[:hfb].presence&.to_i
    @pa   = params[:pa].presence&.to_i
    @hfbs = store.articles.where.not(hfb: nil).distinct.order(:hfb).pluck(:hfb)
    @pas  = @hfb ? store.articles.where(hfb: @hfb).where.not(pa: nil).distinct.order(:pa).pluck(:pa) : []
    @pa   = nil unless @pas.include?(@pa)

    @placements_by_section = Placement.where(section_id: @sections.ids)
                                      .joins(:article).includes(:article)
                                      .order(Article.arel_table[:FCST].desc.nulls_last)
                                      .group_by(&:section_id)
  end

  # POST /aisles/:aisle_id/sections/plan_voss
  def plan_voss
    hfb = params[:hfb].presence&.to_i
    pa  = params[:pa].presence&.to_i

    unless VossPlannerService.voss_aisle?(@aisle)
      redirect_to aisle_sections_path(@aisle),
                  alert: "Voss articles can only be planned in aisle #{VossPlannerService::VOSS_AISLE}."
      return
    end

    if hfb.nil?
      redirect_to aisle_sections_path(@aisle), alert: "Select an HFB first."
      return
    end

    sections = @aisle.sections.to_a
    if sections.size != 1
      redirect_to aisle_sections_path(@aisle, hfb: hfb, pa: pa),
                  alert: "Aisle #{VossPlannerService::VOSS_AISLE} must have exactly 1 section (it has #{sections.size})."
      return
    end

    count = VossPlannerService.new(
      @aisle.store,
      section:       sections.first,
      hfb:           hfb,
      pa:            pa,
      article_limit: params[:article_limit].presence&.to_i,
      max_height:    number_param(:max_height),
      max_length:    number_param(:max_length),
      max_width:     number_param(:max_width),
      max_weight:    number_param(:max_weight),
      max_fcst:      number_param(:max_fcst)
    ).call

    scope = pa ? "PA #{pa}" : "HFB #{hfb}"
    redirect_to aisle_sections_path(@aisle, hfb: hfb, pa: pa),
                notice: "#{count} #{"article".pluralize(count)} planned in Voss mode for #{scope}."
  end

  # GET /aisles/:aisle_id/sections/export_voss.csv
  def export_voss
    placements = Placement.where(store: @aisle.store, mode: VossPlannerService::MODE)
                          .includes(:article).joins(:article)
    placements = placements.where(articles: { hfb: params[:hfb] }) if params[:hfb].present?
    placements = placements.where(articles: { pa: params[:pa] })   if params[:pa].present?

    csv = CSV.generate do |rows|
      rows << %w[Slid_h artno artname_unicode new_slid]
      placements.each do |p|
        a = p.article
        rows << [Array(a["SLID"]).join(", "), a["ARTNO"], a["ARTNAME_UNICODE"], p.new_slid]
      end
    end

    send_data csv, filename: "voss_plan_#{Date.current}.csv", type: "text/csv"
  end

  # GET /sections/1 or /sections/1.json
  def show
  end

  # GET /sections/new
  def new
    @section = @aisle.sections.build
  end

  # GET /sections/1/edit
  def edit
  end

  # POST /sections or /sections.json
  def create
    @section = @aisle.sections.build(section_params)

    respond_to do |format|
      if @section.save
        format.html { redirect_to @section, notice: "Section was successfully created." }
        format.json { render :show, status: :created, location: @section }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @section.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /sections/1 or /sections/1.json
  def update
    respond_to do |format|
      if @section.update(section_params)
        format.html { redirect_to @section, notice: "Section was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @section }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @section.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /sections/1 or /sections/1.json
  def destroy
    aisle = @section.aisle
    @section.destroy!

    respond_to do |format|
      format.html { redirect_to aisle_sections_path(aisle), notice: "Section was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_section
      @section = Section.find(params.expect(:id))
    end

    def get_aisle
      @aisle = Aisle.find(params[:aisle_id])
    end

    def number_param(key)
      s = params[key].to_s.strip.tr(",", ".")
      s.empty? ? nil : Float(s, exception: false)
    end

    # Only allow a list of trusted parameters through.
    def section_params
      params.expect(section: [ :Sec_num, :sec_width, :sec_length, :sec_depth, :sec_height, :aisle_id ])
    end
end