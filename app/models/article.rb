# article.rb
class Article < ApplicationRecord
  belongs_to :store
  has_many :placements, dependent: :destroy

  attribute :planned, :boolean, default: false

  # Set by the article edit form only: editing new_slid there = manual planning
  attr_accessor :manual_planning

  # A new article is never planned — no matter what was passed in
  after_initialize { self.planned = false if new_record? }
  before_create    { self.planned = false }

  before_validation :prepare_manual_plan, if: -> { manual_planning && persisted? }
  validate          :manual_location_found
  after_save        :apply_manual_plan, if: -> { @manual_plan }
  after_save        :release_dropped_locations, if: -> { @dropped_slids.present? }

  private

  # Works out what the edit form asked for:
  #   new_slid cleared          -> unplan the article
  #   new_slid changed / not placed there yet -> place it there manually
  #   a location removed from SLID -> its planner placement is removed, so the space is free again
  def prepare_manual_plan
    @manual_plan     = nil
    @manual_location = nil
    @dropped_slids   = nil

    slid          = AislePlannerService.normalize_slid(new_slid)
    self.new_slid = slid.presence

    if slid.blank?
      @manual_plan = :clear if will_save_change_to_new_slid?
    elsif will_save_change_to_new_slid? || Placement.where(article_id: id, new_slid: slid).none?
      @manual_plan     = :assign
      @manual_location = AislePlannerService.manual_location(store, slid)
    end

    # A manual plan already replaces every placement, so dropped locations only matter without one
    if @manual_plan.nil? && will_save_change_to_attribute?("SLID")
      before = AislePlannerService.slids({ "SLID" => attribute_in_database("SLID") })
      after  = AislePlannerService.slids({ "SLID" => self["SLID"] })
      @dropped_slids = before - after
    end
  end

  def manual_location_found
    return unless @manual_plan == :assign && @manual_location.nil?
    errors.add(:new_slid, "#{new_slid} is not a location in any aisle of this store")
  end

  # A manually planned article is ONLY at its new_slid; every other placement is removed
  def apply_manual_plan
    plan         = @manual_plan
    @manual_plan = nil

    Placement.where(article_id: id).delete_all

    if plan == :clear
      update_column(:planned, false)
      return
    end

    section, level = @manual_location
    Placement.create!(
      store:      store,
      article:    self,
      section_id: section.id,
      level_id:   level&.id,
      mode:       AislePlannerService::MANUAL_MODE,
      new_slid:   new_slid,
      quantity:   manual_quantity(level)
    )
    update_column(:planned, true)
  end

  # Locations taken out of SLID: their Aisles placements are deleted, so the next
  # Plan aisle sees that space as free. Manual placements are never touched.
  def release_dropped_locations
    dropped        = @dropped_slids
    @dropped_slids = nil

    Placement.where(article_id: id, mode: AislePlannerService::MODE, new_slid: dropped).delete_all

    remaining = Placement.where(article_id: id).order(:id).pluck(:new_slid)
    if remaining.empty?
      update_columns(planned: false, new_slid: nil)
    elsif dropped.include?(new_slid)
      update_column(:new_slid, remaining.first)
    end
  end

  # Voss: RSSQ, PALLET: PALQ, level 00: PALQ, upper levels: MIN
  def manual_quantity(level)
    return self["RSSQ"] if new_slid == VossPlannerService::NEW_SLID
    return self["PALQ"] if new_slid == PalletPlannerService::NEW_SLID
    level.lev_num.to_i == AislePlannerService::GROUND ? self["PALQ"] : self["MIN"]
  end
end