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

    def self.create(user, name:, grade:)
      raise Discourse::InvalidAccess unless user&.staff? && !user.silenced? && !user.suspended?
      name = name.to_s.strip.unicode_normalize(:nfkc)
      raise Discourse::InvalidParameters.new("name") unless name.length.between?(1, 80)
      raise Discourse::InvalidParameters.new("grade") unless grade.to_s.match?(/\A[1-4]\z/)
      DistributedMutex.synchronize("isbf-learning-courses") do
        PluginStoreRow.transaction do
          courses = list
          if courses.any? { |course| course["grade"] == grade.to_i && course["name"].casecmp?(name) }
            raise Discourse::InvalidParameters.new(I18n.t("isbf_learning.duplicate_course"))
          end
          raise Discourse::InvalidParameters.new("courses") if courses.length >= 1000
          course = { "id" => SecureRandom.uuid, "name" => name, "grade" => grade.to_i }
          raise StorageError unless PluginStore.set(STORE, "courses", courses + [course])
          course.with_indifferent_access
        end
      end
    end
  end
end
