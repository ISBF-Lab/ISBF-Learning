# frozen_string_literal: true

require "digest"

module IsbfLibrary
  module DirectoryDeletion
    Changed = IsbfLearning::DirectoryDeletion::Changed

    def self.plan(user, kind:, id:)
      authorize!(user)
      Catalog.synchronize { build_plan(user, selection(kind, id)) }
    end

    def self.delete(user, kind:, id:, confirmation_token:, confirmation_count:, cascade:)
      authorize!(user)
      PluginStoreRow.transaction do
        Catalog.synchronize do
          selected = selection(kind, id)
          plan = build_plan(user, selected)
          expected = verifier.verified(confirmation_token.to_s)
          valid_confirmation =
            expected == verification_payload(user, selected) &&
              confirmation_count.to_s == plan[:required_confirmations].to_s &&
              (!plan[:has_children] || cascade == true || cascade == "true")
          raise Changed unless valid_confirmation

          topics = resources(selected[:courses]).order(:id).lock.includes(:first_post).to_a
          topics.each do |topic|
            user.guardian.ensure_can_delete!(topic)
            raise IsbfLearning::StorageError unless topic.first_post
          end
          topics.each do |topic|
            PostDestroyer.new(user, topic.first_post).destroy
            raise IsbfLearning::StorageError unless Topic.with_deleted.find(topic.id).deleted_at
          end

          now = Time.now.utc.iso8601
          ids = selected[:courses].map { |course| course["id"] }
          catalog = Catalog.list(include_deleted: true)
          catalog.each do |course|
            next if ids.exclude?(course["id"])
            course["deleted_at"] = now
            course["deleted_by_id"] = user.id
            course["deleted_topic_ids"] = topics
              .select { |topic| topic.custom_fields[GROUP_FIELD] == course["id"] }
              .map(&:id)
          end
          raise IsbfLearning::StorageError unless PluginStore.set(STORE, "groups", catalog)
          if selected[:kind] == "grade"
            parents = Catalog.categories(include_deleted: true)
            parent = parents.find { |entry| entry["id"] == selected[:id] }
            parent["deleted_at"] = now
            parent["deleted_by_id"] = user.id
            raise IsbfLearning::StorageError unless PluginStore.set(STORE, "categories", parents)
          end
          { success: true, deleted_courses: ids, deleted_resources: topics.length }
        end
      end
    end

    def self.authorize!(user)
      IsbfLibrary.ensure_can_submit!(user, user.guardian)
      raise Discourse::InvalidAccess unless IsbfLibrary.can_manage?(user.guardian)
    end

    def self.selection(kind, id)
      case kind
      when "course"
        course = Catalog.find(id)
        raise Discourse::NotFound unless course
        { kind: kind, id: course["id"], name: course["name"], courses: [course] }
      when "grade"
        grade = Catalog.grades.find { |entry| entry[:id].to_s == id.to_s }
        raise Discourse::NotFound unless grade
        {
          kind: kind,
          id: grade[:id].to_s,
          name: grade[:label],
          courses: Catalog.list.select { |entry| entry["category_id"] == grade[:id] },
        }
      else
        raise Discourse::InvalidParameters.new("kind")
      end
    end

    def self.resources(courses)
      Topic.where(category_id: IsbfLibrary.category_id, archetype: Archetype.default).where(
        id:
          TopicCustomField.where(
            name: GROUP_FIELD,
            value: courses.map { |course| course["id"] },
          ).select(:topic_id),
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
            [selected[:name], selected[:courses].sort_by { |course| course["id"] }, scope].to_json,
          ),
      }
    end

    def self.build_plan(user, selected)
      count = resources(selected[:courses]).count
      children = selected[:kind] == "grade" ? selected[:courses].any? : count.positive?
      {
        kind: selected[:kind],
        id: selected[:id],
        name: selected[:name],
        course_count: selected[:courses].length,
        resource_count: count,
        has_children: children,
        required_confirmations: children ? 3 : 2,
        confirmation_token:
          verifier.generate(verification_payload(user, selected), expires_in: 10.minutes),
      }
    end

    def self.verifier
      Rails.application.message_verifier("isbf-library-directory-deletion")
    end

    private_class_method :authorize!,
                         :selection,
                         :resources,
                         :verification_payload,
                         :build_plan,
                         :verifier
  end
end
