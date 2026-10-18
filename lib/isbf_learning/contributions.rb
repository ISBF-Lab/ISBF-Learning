# frozen_string_literal: true

module IsbfLearning
  module Contributions
    PAGE_SIZE = 20

    def self.list(user, guardian, page:)
      scope =
        Topic
          .visible
          .secured(guardian)
          .where(
            category_id: IsbfLearning.category_id,
            archetype: Archetype.default
          )
          .joins(:first_post)
          .where(
            posts: {
              hidden: false,
              user_deleted: false,
              deleted_at: nil,
              post_type: Post.types[:regular]
            }
          )
      assigned =
        TopicCustomField.where(
          name: CONTRIBUTOR_USER_FIELD,
          value: user.id.to_s
        ).select(:topic_id)
      attributed =
        TopicCustomField
          .where(name: CONTRIBUTOR_USER_FIELD)
          .where.not(value: [nil, ""])
          .select(:topic_id)
      scope =
        scope.where(id: assigned).or(
          scope.where(posts: { user_id: user.id }).where.not(id: attributed)
        )
      courses = Courses.list.index_by { |course| course["id"] }
      valid_courses = courses.keys
      scope =
        scope.where(
          id:
            TopicCustomField.where(
              name: COURSE_FIELD,
              value: valid_courses
            ).select(:topic_id)
        )
      topics =
        scope
          .includes(:_custom_fields, first_post: :user)
          .order(created_at: :desc, id: :desc)
          .offset(page * PAGE_SIZE)
          .limit(PAGE_SIZE + 1)
          .to_a
      {
        resources:
          topics
            .first(PAGE_SIZE)
            .filter_map do |topic|
              IsbfLearning.resource(topic, guardian, courses: courses)
            end,
        has_more: topics.length > PAGE_SIZE
      }
    end
  end
end
