class Aisle < ApplicationRecord
  belongs_to :store
  has_many :sections, dependent: :destroy
  has_many :articles, through: :sections

  # The aisle on the other side of a back-to-back rack (e.g. 03 and 05).
  # The link always goes both ways: linking 03 to 05 also links 05 to 03.
  belongs_to :linked_aisle, class_name: "Aisle", optional: true

  # Depth (MAXLENGTH, mm) every new aisle gets from its RACKTYPE. PALLET and 990100 are left as they are.
  RACK_DEPTHS     = { "IKEA" => 2000, "EURO" => 1650 }.freeze
  NO_RACK_DEPTH   = %w[PALLET 990100].freeze

  def self.rack_depth(racktype)
    RACK_DEPTHS[racktype.to_s.strip.upcase]
  end

  def self.rack_depth_aisle?(aisle_num)
    !NO_RACK_DEPTH.include?(aisle_num.to_s.strip.upcase)
  end

  validate :linked_aisle_allowed

  before_create :set_rack_depth

  after_update :update_sections_depth, if: :saved_change_to_MAXLENGTH?
  after_save   :sync_linked_aisle,     if: :saved_change_to_linked_aisle_id?

  private

  def set_rack_depth
    depth = self.class.rack_depth(self["RACKTYPE"])
    self["MAXLENGTH"] = depth if depth && self.class.rack_depth_aisle?(aisle_num)
  end

  def update_sections_depth
    sections.update_all(sec_depth: self.MAXLENGTH)
    AislePlannerService.refresh_shared_depths(self) if linked_aisle_id
  end

  def linked_aisle_allowed
    return if linked_aisle_id.blank?
    errors.add(:linked_aisle_id, "can't be the aisle itself") if linked_aisle_id == id
    errors.add(:linked_aisle_id, "must be in the same store") if linked_aisle && linked_aisle.store_id != store_id
  end

  # Keeps the link two-way and one-to-one:
  #   - the old partner is unlinked
  #   - anything else linked to this aisle or the new partner is unlinked
  #   - the new partner points back at this aisle
  #   - sec_depth: unlinked aisles go back to MAXLENGTH, the new pair gets the shared depth
  def sync_linked_aisle
    old_id, new_id = saved_change_to_linked_aisle_id
    unlinked = []

    if old_id
      unlinked += Aisle.where(id: old_id, linked_aisle_id: id).pluck(:id)
      Aisle.where(id: old_id, linked_aisle_id: id).update_all(linked_aisle_id: nil)
    end

    if new_id
      others = Aisle.where(linked_aisle_id: [id, new_id]).where.not(id: [id, new_id])
      unlinked += others.pluck(:id)
      others.update_all(linked_aisle_id: nil)
      Aisle.where(id: new_id).update_all(linked_aisle_id: id)
    else
      unlinked << id
    end

    Aisle.where(id: unlinked.uniq).each { |a| AislePlannerService.reset_depths(a) }
    AislePlannerService.refresh_shared_depths(Aisle.find(id)) if new_id
  end
end