# frozen_string_literal: true

module IsbfLearning
  module AdminReviewScope
    def viewable_by(user, **options)
      scope = super
      return scope if user&.admin?
      scope.where(
        "NOT (reviewables.type = :type AND (COALESCE(reviewables.category_id, 0) = :category_id OR COALESCE(reviewables.payload ->> :course_field, '') <> ''))",
        type: "ReviewableQueuedPost", category_id: IsbfLearning.category_id || -1,
        course_field: IsbfLearning::COURSE_FIELD,
      )
    end
  end

  module AdminReviewPermission
    private

    def can_review_target?(guardian)
      if IsbfLearning.learning_reviewable?(self)
        return false unless guardian.is_admin? && category && guardian.can_see_category?(category)
        return false if guardian.user.silenced? || guardian.user.suspended?
      end
      super
    end
  end

  module ContributorReviewSerializer
    def cooked
      body = super
      return body unless IsbfLearning.learning_reviewable?(object)
      name = object.payload[IsbfLearning::CONTRIBUTOR_FIELD].presence ||
        IsbfLearning.contributor_name(object.target_created_by)
      "#{body}<p>#{CGI.escapeHTML(I18n.t('isbf_learning.contributor_label'))}: #{CGI.escapeHTML(name)}</p>"
    end
  end
end

Reviewable.singleton_class.prepend(IsbfLearning::AdminReviewScope)
Reviewable.prepend(IsbfLearning::AdminReviewPermission)
ReviewableQueuedPost.before_validation do
  self.reviewable_by_moderator = false if IsbfLearning.learning_reviewable?(self)
end
ReviewableQueuedPostSerializer.payload_attributes(IsbfLearning::CONTRIBUTOR_FIELD.to_sym)
ReviewableQueuedPostSerializer.prepend(IsbfLearning::ContributorReviewSerializer)
