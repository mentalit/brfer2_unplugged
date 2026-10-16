class Placement < ApplicationRecord
  MODES = %w[voss pallet aisles].freeze

  belongs_to :store
  belongs_to :article
  belongs_to :section, optional: true
  belongs_to :level,   optional: true

  validates :mode, inclusion: { in: MODES }
end
