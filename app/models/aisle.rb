class Aisle < ApplicationRecord
  belongs_to :store
  has_many :sections, dependent: :destroy

  after_update :update_sections_depth, if: :saved_change_to_MAXLENGTH?

  private

  def update_sections_depth
    sections.update_all(sec_depth: self.MAXLENGTH)
  end
end
