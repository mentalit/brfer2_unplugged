class Section < ApplicationRecord
  belongs_to :aisle
  has_many :levels
end
