require "csv"

class SectionsController < ApplicationController
  before_action :set_section, only: %i[ show edit update destroy ]
  before_action :get_aisle, only: %i[ new create index plan_voss export_voss plan_aisle unplan_aisle unassign_article export_all ]

  # GET /sections or /sections.json
  def index
    @sections        = @aisle.sections.includes(:levels).order(:Sec_num)
    @voss_aisle      = VossPlannerService.voss_aisle?(@aisle)
    @aisle_plannable = AislePlannerService.plannable_aisle?(@aisle)
    store            = @aisle.store

    @hfb  = params[:hfb].presence&.to_i
    @pa   = params[:pa].presence&.to_i
    @hfbs = store.articles.where.not(hfb: nil).distinct.order(:hfb).pluck(:hfb)
    @pas  = @hfb ? store.articles.where(hfb: @hfb).where.not(pa: nil).distinct.order(:pa).pluck(:pa) : []
    @pa   = nil unless @pas.include?(@pa)

    @end_date   = date_param(:end_date)
    @start_date = date_param(:start_date)
    @max_fcst   = number_param(:max_fcst)
    @ignore_weight = params[:ignore_weight] == "1"

    @placements = Placement.where(section_id: @sections.map(&:id))
                           .joins(:article).includes(:article)
                           .order(:new_slid)
                           .order(Article.arel_table[:FCST].desc.nulls_last)

    # { section_id => { level_id => [placements] } }
    @grouped = @placements.group_by(&:section_id)
                          .transform_values { |ps| ps.group_by(&:level_id) }
  end

  def unassign_article
    article = @aisle.store.articles.find(params[:article_id])
    removed = 0

    ActiveRecord::Base.transaction do
      # Aisles the article was in — linked ones get their shared level 00 depth updated
      aisle_ids = Section.where(id: Placement.where(article_id: article.id).select(:section_id)).distinct.pluck(:aisle_id)

      removed = Placement.where(article_id: article.id).delete_all
      article.update_columns(planned: false, new_slid: nil)

      Aisle.where(id: aisle_ids).where.not(linked_aisle_id: nil)
           .each { |a| AislePlannerService.refresh_shared_depths(a) }
    end

    redirect_to aisle_sections_path(@aisle, hfb: params[:hfb].presence, pa: params[:pa].presence,
                                    end_date: params[:end_date].presence, start_date: params[:start_date].presence,
                                    max_fcst: params[:max_fcst].presence),
                notice: "#{article["ARTNO"]} unassigned: #{removed} #{"location".pluralize(removed)} removed."
  end



  # POST /aisles/:aisle_id/sections/plan_aisle
  def plan_aisle
    hfb        = params[:hfb].presence&.to_i
    pa         = params[:pa].presence&.to_i
    end_date   = date_param(:end_date)
    start_date = date_param(:start_date)
    max_fcst   = number_param(:max_fcst)
    ignore_wt  = params[:ignore_weight] == "1"
    back       = aisle_sections_path(@aisle, hfb: hfb, pa: pa, end_date: end_date,
                                     start_date: start_date, max_fcst: max_fcst,
                                     ignore_weight: ("1" if ignore_wt))

    unless AislePlannerService.plannable_aisle?(@aisle)
      redirect_to back, alert: "Aisle mode cannot plan aisle #{@aisle.aisle_num}."
      return
    end

    r = AislePlannerService.new(@aisle, hfb: hfb, pa: pa, end_date: end_date,
                                start_date: start_date, max_fcst: max_fcst,
                                ignore_weight: ignore_wt).call

    redirect_to back,
                notice: "Aisle #{@aisle.aisle_num}: #{r[:candidates]} to plan — " \
                        "#{r[:manual].to_i} manual, #{r[:kept].to_i} kept from earlier planning, " \
                        "#{r[:in_place]} at own slid_h, #{r[:placed]} newly planned, " \
                        "#{r[:no_room]} no room, #{r[:too_deep]} too deep, #{r[:skipped]} skipped."
  end

  # DELETE /aisles/:aisle_id/sections/unplan_aisle
  # Manually planned articles are never unplanned
  def unplan_aisle
    placements = Placement.where(section_id: @aisle.sections.select(:id))
                          .where.not(mode: AislePlannerService::MANUAL_MODE)
    ids        = placements.distinct.pluck(:article_id)
    removed    = 0

    ActiveRecord::Base.transaction do
      removed = placements.delete_all
      Article.where(id: ids).where.not(id: Placement.select(:article_id))
             .update_all(planned: false, new_slid: nil)

      # Back-to-back aisle: this aisle and the one behind it get their shared level 00 depth updated
      AislePlannerService.refresh_shared_depths(@aisle) if @aisle.linked_aisle_id
    end

    redirect_to aisle_sections_path(@aisle, hfb: params[:hfb].presence, pa: params[:pa].presence,
                                    end_date: params[:end_date].presence, start_date: params[:start_date].presence,
                                    max_fcst: params[:max_fcst].presence),
                notice: "Aisle #{@aisle.aisle_num} emptied: #{removed} #{"placement".pluralize(removed)} removed."
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

    # Remember the excluded names for the next Voss planning (kept in this browser's session)
    session[:voss_exclude_names] = params[:exclude_names].to_s.strip

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
      max_fcst:      number_param(:max_fcst),
      exclude_names: params[:exclude_names],
      dt_one_only:   params[:dt_one_only] == "1"
    ).call

    scope = pa ? "PA #{pa}" : "HFB #{hfb}"
    scope += ", DT = 1 only" if params[:dt_one_only] == "1"
    redirect_to aisle_sections_path(@aisle, hfb: hfb, pa: pa),
                notice: "#{count} #{"article".pluralize(count)} planned in Voss mode for #{scope}."
  end

  # GET /aisles/:aisle_id/sections/export_voss.csv
  def export_voss
    base       = Placement.where(store: @aisle.store)
    placements = base.where(mode: VossPlannerService::MODE)
                     .or(base.where(mode: AislePlannerService::MANUAL_MODE, new_slid: VossPlannerService::NEW_SLID))
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

  # GET /aisles/:aisle_id/sections/export_all.csv
  # Every aisle of the store, in aisle order, each with a title row ("Aisle 03 FS") and the
  # column headers — also aisles with nothing planned yet. Under each aisle: every planned
  # article in it (Voss, PALLET, Aisles and manual), one row per location.
  # The file can be uploaded again with "Plan CSV": the title and header rows have no artno,
  # so the upload skips them.
  def export_all
    store      = @aisle.store
    aisles     = store.aisles.to_a.sort_by { |a| aisle_sort_key(a) }
    placements = Placement.where(store: store)
                          .includes(:article, :section).joins(:article)
                          .to_a
    by_aisle   = placements.group_by { |p| p.section&.aisle_id }

    headers = %w[Slid_h artno artname_unicode new_slid quantity mode]

    write_aisle = lambda do |rows, title, list, first|
      unless first
        rows << []
        rows << [title]
        rows << headers
      else
        rows << [title]
      end

      list.sort_by { |p| [p.new_slid.to_s, p.article["ARTNO"].to_s] }.each do |p|
        a = p.article
        rows << [Array(a["SLID"]).join(", "), a["ARTNO"], a["ARTNAME_UNICODE"], p.new_slid, p.quantity, p.mode]
      end
    end

    csv = CSV.generate do |rows|
      rows << headers

      aisles.each_with_index do |aisle, i|
        write_aisle.call(rows, "Aisle #{aisle.aisle_num}", by_aisle[aisle.id] || [], i.zero?)
      end

      # Placements without a section (should not happen) still go in the file
      if by_aisle[nil].present?
        write_aisle.call(rows, "No aisle", by_aisle[nil], aisles.empty?)
      end
    end

    # The name ends in "plan_<date>" so the Plan CSV upload accepts it
    send_data csv, filename: "all_plan_#{Date.current}.csv", type: "text/csv"
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

    # Aisles in number order: 01 FS, 01 SS, 02 FS ... then Voss / PALLET
    def aisle_sort_key(aisle)
      num = aisle.aisle_num.to_s.strip
      num.match?(/\A\d{1,2}\s/) ? format("%02d %s", num.to_i, num.sub(/\A\d+\s*/, "")) : "~#{num}"
    end

    def number_param(key)
      s = params[key].to_s.strip.tr(",", ".")
      s.empty? ? nil : Float(s, exception: false)
    end

    def date_param(key)
      Date.iso8601(params[key].to_s)
    rescue Date::Error
      nil
    end

    # Only allow a list of trusted parameters through.
    def section_params
      params.expect(section: [ :Sec_num, :sec_width, :sec_length, :sec_depth, :sec_height, :unlinked, :aisle_id ])
    end
end