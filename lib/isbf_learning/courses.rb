# frozen_string_literal: true

require "securerandom"

module IsbfLearning
  module Courses
    def self.list
      (PluginStore.get(STORE, "courses") || []).map(&:with_indifferent_access)
    end

    def self.find(id)
      list.find { |course| course["id"] == id.to_s }
    end

    def self.normalize(name:, grade:)
      raise Discourse::InvalidParameters.new("name") unless name.is_a?(String)
      name = name.strip.unicode_normalize(:nfkc)
      unless name.length.between?(1, 80)
        raise Discourse::InvalidParameters.new("name")
      end
      unless grade.to_s.match?(/\A[1-4]\z/)
        raise Discourse::InvalidParameters.new("grade")
      end
      { "name" => name, "grade" => grade.to_i }
    end

    # Hold the catalog mutex through the outer review transaction's commit.
    def self.synchronize(&block)
      DistributedMutex.synchronize("isbf-learning-courses", &block)
    end

    def self.create(user, name:, grade:)
      ensure_staff!(user)
      attributes = normalize(name: name, grade: grade)
      synchronize { add(attributes) }
    end

    def self.request(user, name:, grade:)
      IsbfLearning.ensure_can_submit!(user, Guardian.new(user))
      attributes = normalize(name: name, grade: grade)
      synchronize do
        if matching(attributes)
          raise Discourse::InvalidParameters.new(
                  I18n.t("isbf_learning.duplicate_course")
                )
        end
        pending =
          ReviewableIsbfLearningCourse
            .pending
            .where(
              created_by_id: user.id,
              category_id: IsbfLearning.category_id
            )
            .detect do |reviewable|
              stored =
                normalize(
                  name: reviewable.payload["course_name"],
                  grade: reviewable.payload["grade"]
                )
              stored["grade"] == attributes["grade"] &&
                stored["name"].casecmp?(attributes["name"])
            end
        next pending if pending
        reviewable =
          ReviewableIsbfLearningCourse.new(
            created_by: user,
            target_created_by: user,
            category_id: IsbfLearning.category_id,
            payload: {
              "course_name" => attributes["name"],
              "grade" => attributes["grade"]
            },
            reviewable_by_moderator: true,
            force_review: true,
            potential_spam: false
          )
        reviewable.created_new!
        reviewable.save!
        reviewable
      end
    end

    # Called inside ReviewableIsbfLearningCourse#perform's shared catalog lock.
    def self.approve_locked(user, name:, grade:)
      ensure_staff!(user, review: true)
      add(normalize(name: name, grade: grade), reuse_existing: true)
    end

    def self.ensure_staff!(user, review: false)
      permitted =
        user &&
          (
            if review
              IsbfLearning.can_review?(user.guardian)
            else
              IsbfLearning.can_manage?(user.guardian)
            end
          )
      permitted ||=
        user&.staff? &&
          !(
            SiteSetting.respond_to?(:academy_roles_enabled?) &&
              SiteSetting.academy_roles_enabled?
          )
      unless permitted && !user.silenced? && !user.suspended?
        raise Discourse::InvalidAccess
      end
    end

    def self.matching(attributes)
      list.find do |course|
        course["grade"] == attributes["grade"] &&
          course["name"].casecmp?(attributes["name"])
      end
    end

    def self.add(attributes, reuse_existing: false)
      if existing = matching(attributes)
        return existing if reuse_existing
        raise Discourse::InvalidParameters.new(
                I18n.t("isbf_learning.duplicate_course")
              )
      end
      courses = list
      if courses.length >= 1000
        raise Discourse::InvalidParameters.new("courses")
      end
      course = attributes.merge("id" => SecureRandom.uuid)
      unless PluginStore.set(STORE, "courses", courses + [course])
        raise StorageError
      end
      course.with_indifferent_access
    end

    private_class_method :add, :matching, :ensure_staff!
  end
end
