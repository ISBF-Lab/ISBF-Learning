# frozen_string_literal: true

require "securerandom"

module IsbfLearning
  module Courses
    def self.list(include_deleted: false)
      courses =
        (PluginStore.get(STORE, "courses") || []).map(&:with_indifferent_access)
      if include_deleted
        courses
      else
        courses.reject { |course| course["deleted_at"].present? }
      end
    end

    def self.find(id)
      list.find { |course| course["id"] == id.to_s }
    end

    def self.grades
      labels = PluginStore.get(STORE, "grade_labels") || {}
      deleted = PluginStore.get(STORE, "deleted_grades") || {}
      custom =
        (PluginStore.get(STORE, "custom_grades") || []).map do |entry|
          { id: entry["id"], label: entry["label"] }
        end
      (GRADES + custom)
        .reject { |grade| deleted.key?(grade[:id].to_s) }
        .map do |grade|
          grade.merge(label: labels[grade[:id].to_s].presence || grade[:label])
        end
    end

    def self.create_grade(user, name:)
      raise Discourse::InvalidAccess unless user&.guardian&.is_admin?
      IsbfLearning.ensure_can_submit!(user, user.guardian)
      synchronize do
        label = normalize_name(name)
        if grades.any? { |grade| grade[:label].casecmp?(label) }
          raise Discourse::InvalidParameters.new("name")
        end
        custom = PluginStore.get(STORE, "custom_grades") || []
        if custom.length >= 1000
          raise Discourse::InvalidParameters.new("grades")
        end
        id =
          (
            GRADES.map { |grade| grade[:id] } +
              custom.map { |grade| grade["id"] }
          ).max + 1
        grade = { "id" => id, "label" => label }
        unless PluginStore.set(STORE, "custom_grades", custom + [grade])
          raise StorageError
        end
        grade
      end
    end

    def self.update(user, id, name:, grade:)
      IsbfLearning.ensure_can_submit!(user, user.guardian)
      unless IsbfLearning.can_manage?(user.guardian)
        raise Discourse::InvalidAccess
      end
      synchronize do
        attributes = normalize(name: name, grade: grade)
        courses = list(include_deleted: true)
        course =
          courses.find do |entry|
            entry["id"] == id.to_s && entry["deleted_at"].blank?
          end
        raise Discourse::NotFound unless course
        if list.any? { |entry|
             entry["id"] != id.to_s && entry["grade"] == attributes["grade"] &&
               entry["name"].casecmp?(attributes["name"])
           }
          raise Discourse::InvalidParameters.new(
                  I18n.t("isbf_learning.duplicate_course")
                )
        end
        course.merge!(attributes)
        raise StorageError unless PluginStore.set(STORE, "courses", courses)
        course
      end
    end

    def self.update_grade(user, id:, name:)
      IsbfLearning.ensure_can_submit!(user, user.guardian)
      unless IsbfLearning.can_manage?(user.guardian)
        raise Discourse::InvalidAccess
      end
      synchronize do
        attributes = normalize(name: name, grade: id)
        if grades.any? { |grade|
             grade[:id] != id.to_i && grade[:label].casecmp?(attributes["name"])
           }
          raise Discourse::InvalidParameters.new("name")
        end
        labels = PluginStore.get(STORE, "grade_labels") || {}
        labels[id.to_s] = attributes["name"]
        raise StorageError unless PluginStore.set(STORE, "grade_labels", labels)
        { id: id.to_i, label: attributes["name"] }
      end
    end

    def self.normalize(name:, grade:)
      name = normalize_name(name)
      unless grade.to_s.match?(/\A[1-9]\d{0,9}\z/) &&
               grades.any? { |entry| entry[:id] == grade.to_i }
        raise Discourse::InvalidParameters.new("grade")
      end
      { "name" => name, "grade" => grade.to_i }
    end

    def self.normalize_name(name)
      raise Discourse::InvalidParameters.new("name") unless name.is_a?(String)
      name = name.strip.unicode_normalize(:nfkc)
      unless name.length.between?(1, 80) && !name.match?(/[\p{Cc}]/)
        raise Discourse::InvalidParameters.new("name")
      end
      name
    end

    # Hold the catalog mutex through the outer review transaction's commit.
    def self.synchronize(&block)
      DistributedMutex.synchronize("isbf-learning-courses") do
        with_catalog_lock(&block)
      end
    end

    def self.with_catalog_lock
      result = nil
      PluginStoreRow.transaction(requires_new: true) do
        scope = PluginStoreRow.where(plugin_name: STORE, key: "courses")
        row =
          scope.first ||
            scope.create_or_find_by!({}) do |record|
              record.type_name = "JSON"
              record.value = "[]"
            end
        row.lock!
        result = yield
        # Native review failures can absorb a rollback in their nested transaction.
        if result.respond_to?(:success?) && !result.success?
          raise ActiveRecord::Rollback
        end
      end
      result
    end

    def self.create(user, name:, grade:)
      ensure_staff!(user)
      synchronize { add(normalize(name: name, grade: grade)) }
    end

    def self.request(user, name:, grade:)
      IsbfLearning.ensure_can_submit!(user, Guardian.new(user))
      synchronize do
        attributes = normalize(name: name, grade: grade)
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
              unless grades.any? { |entry|
                       entry[:id].to_s == reviewable.payload["grade"].to_s
                     }
                next false
              end
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
      courses = list(include_deleted: true)
      raise Discourse::InvalidParameters.new("courses") if list.length >= 1000
      course = attributes.merge("id" => SecureRandom.uuid)
      unless PluginStore.set(STORE, "courses", courses + [course])
        raise StorageError
      end
      course.with_indifferent_access
    end

    private_class_method :add, :matching, :ensure_staff!, :normalize_name
  end
end
