class Article < ApplicationRecord
  belongs_to :store

  attribute :planned, :boolean, default: false

  # A new article is never planned unless it was given a location (new_slid)
  after_initialize { self.planned = false if new_record? && new_slid.blank? }
  before_create    { self.planned = false if new_slid.blank? }
end

