# frozen_string_literal: true

require "securerandom"

module IsbfLibrary
  module Catalog
    def self.categories(include_deleted: false)
      (PluginStore.get(STORE, "categories") || [])
        .map(&:with_indifferent_access)
        .reject { |entry| !include_deleted && entry["deleted_at"].present? }
    end

    def self.groups(category_id = nil, include_deleted: false)
      result =
        (PluginStore.get(STORE, "groups") || [])
          .map(&:with_indifferent_access)
          .reject { |entry| !include_deleted && entry["deleted_at"].present? }
      category_id ? result.select { |entry| entry["category_id"] == category_id.to_s } : result
    end

    def self.find_category(id)
      categories.find { |entry| entry["id"] == id.to_s }
    end

    def self.find_group(id)
      groups.find { |entry| entry["id"] == id.to_s }
    end

    def self.normalize(kind:, name:, category_id: nil)
      kind = kind.to_s
      unless %w[category group].include?(kind) && name.is_a?(String)
        raise Discourse::InvalidParameters.new("kind")
      end
      raise Discourse::InvalidParameters.new("name") if name.match?(/[\x00-\x1f\x7f]/)
      name = name.strip.unicode_normalize(:nfkc)
      unless name.length.between?(1, 80) && !name.match?(/[\x00-\x1f\x7f]/)
        raise Discourse::InvalidParameters.new("name")
      end
      result = { "kind" => kind, "name" => name }
      if kind == "group"
        raise Discourse::InvalidParameters.new("category_id") unless find_category(category_id)
        result["category_id"] = category_id.to_s
      elsif category_id.present?
        raise Discourse::InvalidParameters.new("category_id")
      end
      result
    end

    def self.with_catalog_lock(&block)
      DistributedMutex.synchronize("isbf-library-catalog", &block)
    end

    def self.synchronize(&block)
      with_catalog_lock(&block)
    end

    def self.list(include_deleted: false)
      groups(nil, include_deleted: include_deleted)
    end

    def self.find(id)
      find_group(id)
    end

    def self.grades
      categories.map { |entry| { id: entry["id"], label: entry["name"] } }
    end

    def self.update(user, id, name:, grade:)
      update_directory(user, "group", id, name: name, category_id: grade)
    end

    def self.update_grade(user, id:, name:)
      update_directory(user, "category", id, name: name)
    end

    def self.update_directory(user, kind, id, **attributes)
      IsbfLibrary.ensure_can_submit!(user, user.guardian)
      raise Discourse::InvalidAccess unless IsbfLibrary.can_manage?(user.guardian)
      synchronize do
        values = normalize(kind: kind, **attributes)
        entry = kind == "category" ? find_category(id) : find_group(id)
        raise Discourse::NotFound unless entry
        if (existing = matching(values)) && existing["id"] != entry["id"]
          raise Discourse::InvalidParameters.new(I18n.t("isbf_library.duplicate_directory"))
        end
        key = kind == "category" ? "categories" : "groups"
        entries =
          (
            if kind == "category"
              categories(include_deleted: true)
            else
              groups(nil, include_deleted: true)
            end
          )
        updated = entry.merge(values.except("kind"))
        entries.map! { |item| item["id"] == id.to_s ? updated : item }
        raise IsbfLearning::StorageError unless PluginStore.set(STORE, key, entries)
        updated
      end
    end

    def self.create(user, **attributes)
      ensure_staff!(user)
      synchronize { add(normalize(**attributes)) }
    end

    def self.request(user, **attributes)
      IsbfLibrary.ensure_can_submit!(user, Guardian.new(user))
      synchronize do
        values = normalize(**attributes)
        if matching(values)
          raise Discourse::InvalidParameters.new(I18n.t("isbf_library.duplicate_directory"))
        end
        pending =
          ReviewableIsbfLibraryDirectory
            .pending
            .where(created_by_id: user.id, category_id: IsbfLibrary.category_id)
            .detect do |reviewable|
              payload = reviewable.payload
              payload["kind"] == values["kind"] &&
                payload["category_id"] == values["category_id"] &&
                payload["name"].to_s.casecmp?(values["name"])
            end
        next pending if pending
        reviewable =
          ReviewableIsbfLibraryDirectory.new(
            created_by: user,
            target_created_by: user,
            category_id: IsbfLibrary.category_id,
            payload: values,
            reviewable_by_moderator: true,
            force_review: true,
            potential_spam: false,
          )
        reviewable.created_new!
        reviewable.save!
        reviewable
      end
    end

    def self.approve_locked(user, **attributes)
      ensure_staff!(user)
      add(normalize(**attributes), reuse_existing: true)
    end

    def self.ensure_staff!(user)
      IsbfLibrary.ensure_can_submit!(user, user.guardian)
      permitted =
        IsbfLibrary.can_manage?(user.guardian) ||
          (
            user.staff? &&
              !(
                SiteSetting.respond_to?(:academy_roles_enabled?) &&
                  SiteSetting.academy_roles_enabled?
              )
          )
      raise Discourse::InvalidAccess unless permitted
    end

    def self.matching(values)
      entries = values["kind"] == "category" ? categories : groups(values["category_id"])
      entries.find { |entry| entry["name"].casecmp?(values["name"]) }
    end

    def self.add(values, reuse_existing: false)
      if existing = matching(values)
        return existing if reuse_existing
        raise Discourse::InvalidParameters.new(I18n.t("isbf_library.duplicate_directory"))
      end
      key = values["kind"] == "category" ? "categories" : "groups"
      entries =
        key == "categories" ? categories(include_deleted: true) : groups(nil, include_deleted: true)
      raise Discourse::InvalidParameters.new(key) if entries.length >= 1000
      entry = values.except("kind").merge("id" => SecureRandom.uuid)
      raise IsbfLearning::StorageError unless PluginStore.set(STORE, key, entries + [entry])
      entry.with_indifferent_access
    end

    private_class_method :add, :matching, :ensure_staff!
  end
end
