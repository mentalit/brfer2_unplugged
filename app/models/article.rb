class Article < ApplicationRecord
  belongs_to :store
  has_many :placements, dependent: :destroy

  attribute :planned, :boolean, default: false

  # A new article is never planned — no matter what was passed in
  after_initialize { self.planned = false if new_record? }
  before_create    { self.planned = false }
end
