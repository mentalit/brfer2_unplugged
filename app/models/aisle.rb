class Aisle < ApplicationRecord
  belongs_to :store
  has_many :sections, dependent: :destroy
end
