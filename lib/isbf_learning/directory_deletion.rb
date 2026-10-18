# frozen_string_literal: true

require "digest"

module IsbfLearning
  module DirectoryDeletion
    class Changed < StandardError
    end

    def self.plan(user, kind:, id:)
      authorize!(user)
      Courses.synchronize { build_plan(user, selection(kind, id)) }
    end

    def self.delete(
      user,
      kind:,
      id:,
      confirmation_token:,
      confirmation_count:,
      cascade:
    )
      authorize!(user)
      Courses.synchronize do
        selected = selection(kind, id)
        plan = build_plan(user, selected)
        expected = verifier.verified(confirmation_token.to_s)
        valid_confirmation =
          expected == verification_payload(user, selected) &&
            confirmation_count.to_s == plan[:required_confirmations].to_s &&
            (!plan[:has_children] || cascade == true || cascade == "true")
        raise Changed unless valid_confirmation

        topics =
          resources(selected[:courses])
            .order(:id)
            .lock
            .includes(:first_post)
            .to_a
        topics.each do |topic|
          user.guardian.ensure_can_delete!(topic)
          raise StorageError unless topic.first_post
        end
        topics.each do |topic|
          PostDestroyer.new(user, topic.first_post).destroy
          raise StorageError unless Topic.with_deleted.find(topic.id).deleted_at
        end

        now = Time.now.utc.iso8601
        ids = selected[:courses].map { |course| course["id"] }
        catalog = Courses.list(include_deleted: true)
        catalog.each do |course|
          next if ids.exclude?(course["id"])
          course["deleted_at"] = now
          course["deleted_by_id"] = user.id
          course["deleted_topic_ids"] = topics
            .select do |topic|
              topic.custom_fields[COURSE_FIELD] == course["id"]
            end
            .map(&:id)
        end
        raise StorageError unless PluginStore.set(STORE, "courses", catalog)
        if selected[:kind] == "grade"
          archived = PluginStore.get(STORE, "deleted_grades") || {}
          archived[selected[:id]] = {
            "deleted_at" => now,
            "deleted_by_id" => user.id,
            "course_ids" => ids
          }
          unless PluginStore.set(STORE, "deleted_grades", archived)
            raise StorageError
          end
        end
        {
          success: true,
          deleted_courses: ids,
          deleted_resources: topics.length
        }
      end
    end

    def self.authorize!(user)
      IsbfLearning.ensure_can_submit!(user, user.guardian)
      unless IsbfLearning.can_manage?(user.guardian)
        raise Discourse::InvalidAccess
      end
    end

    def self.selection(kind, id)
      case kind
      when "course"
        course = Courses.find(id)
        raise Discourse::NotFound unless course
        {
          kind: kind,
          id: course["id"],
          name: course["name"],
          courses: [course]
        }
      when "grade"
        grade = Courses.grades.find { |entry| entry[:id].to_s == id.to_s }
        raise Discourse::NotFound unless grade
        {
          kind: kind,
          id: grade[:id].to_s,
          name: grade[:label],
          courses: Courses.list.select { |entry| entry["grade"] == grade[:id] }
        }
      else
        raise Discourse::InvalidParameters.new("kind")
      end
    end

    def self.resources(courses)
      Topic.where(
        category_id: IsbfLearning.category_id,
        archetype: Archetype.default
      ).where(
        id:
          TopicCustomField.where(
            name: COURSE_FIELD,
            value: courses.map { |course| course["id"] }
          ).select(:topic_id)
      )
    end

    def self.verification_payload(user, selected)
      scope = resources(selected[:courses]).order(:id).pluck(:id, :updated_at)
      {
        "user_id" => user.id,
        "kind" => selected[:kind],
        "id" => selected[:id],
        "fingerprint" =>
          Digest::SHA256.hexdigest(
            [
              selected[:name],
              selected[:courses].sort_by { |course| course["id"] },
              scope
            ].to_json
          )
      }
    end

    def self.build_plan(user, selected)
      count = resources(selected[:courses]).count
      children =
        selected[:kind] == "grade" ? selected[:courses].any? : count.positive?
      {
        kind: selected[:kind],
        id: selected[:id],
        name: selected[:name],
        course_count: selected[:courses].length,
        resource_count: count,
        has_children: children,
        required_confirmations: children ? 3 : 2,
        confirmation_token:
          verifier.generate(
            verification_payload(user, selected),
            expires_in: 10.minutes
          )
      }
    end

    def self.verifier
      Rails.application.message_verifier("isbf-learning-directory-deletion")
    end

    private_class_method :authorize!,
                         :selection,
                         :resources,
                         :verification_payload,
                         :build_plan,
                         :verifier
  end
end
