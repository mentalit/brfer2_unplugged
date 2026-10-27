class PlanUploadsController < ApplicationController
  def create
    aisle = Aisle.find(params[:aisle_id])

    if params[:plan_file].blank?
      return redirect_to aisle_sections_path(aisle), alert: "Choose a plan CSV to upload."
    end

    r = PlanUploadService.new(aisle.store, params[:plan_file]).call

    msg = "Plan uploaded: #{r[:articles_planned]} articles planned, " \
          "#{r[:placements_created]} placements created, " \
          "#{r[:missing]} artnos not found in the store."
    msg += " Missing: #{r[:missing_artnos].first(20).join(', ')}#{' …' if r[:missing_artnos].size > 20}" if r[:missing_artnos].any?
    msg += " No matching section for: #{r[:unplaced_slids].first(20).join(', ')}#{' …' if r[:unplaced_slids].size > 20}" if r[:unplaced_slids].any?

    redirect_to aisle_sections_path(aisle), notice: msg
  rescue PlanUploadService::UploadError => e
    redirect_to aisle_sections_path(aisle), alert: e.message
  end
end