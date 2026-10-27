class Placement < ApplicationRecord
  MODES = %w[voss pallet aisles manual].freeze

  belongs_to :store
  belongs_to :article
  belongs_to :section, optional: true
  belongs_to :level,   optional: true

  validates :mode, inclusion: { in: MODES }

  # When a placement is destroyed, its article goes back to unplanned
  # once it has no other placement left (an article with several locations stays planned
  # while any of them remain). Skipped when the article itself is being destroyed.
  after_destroy :reset_article

  private

  def reset_article
    return if destroyed_by_association&.active_record == Article
    return if Placement.where(article_id: article_id).exists?

    Article.where(id: article_id).update_all(planned: false, new_slid: nil)
  end
end