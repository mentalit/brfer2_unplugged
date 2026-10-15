class Store < ApplicationRecord
	has_many :aisles
	has_many :articles
end
