require "csv"

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

  # Every placement in this aisle, in the plan CSV format (re-uploadable)
  def export
    aisle = Aisle.find(params[:aisle_id])

    placements = Placement.joins(:section)
                          .where(sections: { aisle_id: aisle.id })
                          .includes(:article)
                          .sort_by { |p| [p.new_slid.to_s, p.article.ARTNO.to_s] }

    csv = CSV.generate do |out|
      out << %w[Slid_h artno artname_unicode new_slid]
      placements.each do |p|
        a = p.article
        out << [slids_for(a).join(", "), a.ARTNO, a.ARTNAME_UNICODE, p.new_slid]
      end
    end

    send_data csv, type: "text/csv", filename: "#{export_name(aisle)}_plan_#{Date.current}.csv"
  end

  private

  def export_name(aisle)
    if %w[990100 VOSS].include?(aisle.aisle_num.to_s.strip.upcase)
      "voss"
    elsif PalletPlannerService.pallet_aisle?(aisle)
      "pallet"
    else
      "aisle_#{aisle.aisle_num.to_s.strip.parameterize(separator: '_')}"
    end
  end

  # Every slid_h of an article, padded to 6 digits (10100 → 010100)
  def slids_for(article)
    Array(article.SLID).flat_map { |s| s.to_s.split(/[\s,;]+/) }
                       .reject(&:empty?)
                       .map { |s| s.match?(/\A\d{5}\z/) ? "0#{s}" : s }
  end
end