require "csv"

class PalletPlansController < ApplicationController
  before_action :get_aisle, only: %i[ create export ]

  # POST /aisles/:aisle_id/pallet/plan
  def create
    hfb = params[:hfb].presence&.to_i
    pa  = params[:pa].presence&.to_i

    unless PalletPlannerService.pallet_aisle?(@aisle)
      redirect_to aisle_sections_path(@aisle),
                  alert: "PALLET articles can only be planned in aisle #{PalletPlannerService::PALLET_AISLE}."
      return
    end

    sections = @aisle.sections
    unless sections.count == 1
      redirect_to aisle_sections_path(@aisle),
                  alert: "Aisle #{PalletPlannerService::PALLET_AISLE} must have exactly one section."
      return
    end

    if hfb.nil?
      redirect_to aisle_sections_path(@aisle), alert: "Select an HFB first."
      return
    end

    count = PalletPlannerService.new(
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
      max_palq:      number_param(:max_palq)
    ).call

    scope = pa ? "PA #{pa}" : "HFB #{hfb}"
    redirect_to aisle_sections_path(@aisle, hfb: hfb, pa: pa),
                notice: "#{count} #{"article".pluralize(count)} planned in PALLET mode for #{scope}."
  end

  # GET /aisles/:aisle_id/pallet/export.csv
  def export
    base       = Placement.where(store: @aisle.store)
    placements = base.where(mode: PalletPlannerService::MODE)
                     .or(base.where(mode: AislePlannerService::MANUAL_MODE, new_slid: PalletPlannerService::NEW_SLID))
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

    send_data csv, filename: "pallet_plan_#{Date.current}.csv", type: "text/csv"
  end

  private

  def get_aisle
    @aisle = Aisle.find(params[:aisle_id])
  end

  def number_param(key)
    s = params[key].to_s.strip.tr(",", ".")
    s.empty? ? nil : Float(s, exception: false)
  end
end