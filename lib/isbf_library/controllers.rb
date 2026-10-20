# frozen_string_literal: true

module IsbfLibrary
  class Engine < ::Rails::Engine
    engine_name "isbf-library"
    isolate_namespace IsbfLibrary
  end

  class LibraryController < IsbfLearning::LibraryController
    wrap_parameters false
    requires_login
    requires_plugin "isbf-learning"
    before_action :check_category

    def page
      render html: "".html_safe, layout: "application"
    end

    def categories
      render json: { categories: Catalog.categories }
    end

    def groups
      if params[:category_id].present? && !Catalog.find_category(params[:category_id])
        raise Discourse::InvalidParameters.new("category_id")
      end
      render json: { groups: Catalog.groups(params[:category_id].presence) }
    end

    def create_category
      create_directory("category")
    end

    def create_group
      create_directory("group")
    end

    def resources
      page = params[:page].presence || "0"
      raise Discourse::InvalidParameters.new("page") unless page.to_s.match?(/\A\d{1,4}\z/)
      page = page.to_i
      query = params[:q].to_s.strip
      if query.present?
        raise Discourse::InvalidParameters.new("q") if query.length > 200
        RateLimiter.new(current_user, "isbf-library-search", 30, 1.minute).performed!
        results =
          Search.new(
            "#{query} isbf-library:library in:first",
            guardian: guardian,
            search_type: :full_page,
            type_filter: "topic",
            page: page + 1,
            search_context: Category.find(IsbfLibrary.category_id),
          ).execute
        raise Discourse::InvalidParameters.new("q") if results.error
        topics = results.posts.map(&:topic).uniq(&:id)
        more = results.more_full_page_results || results.more_posts
      else
        return render json: { resources: [], has_more: false } if params[:group_id].blank?
        group = Catalog.find_group(params[:group_id])
        unless group && Catalog.find_category(group["category_id"])
          raise Discourse::InvalidParameters.new("group_id")
        end
        limit = 20
        scope =
          Topic
            .visible
            .secured(guardian)
            .where(category_id: IsbfLibrary.category_id, archetype: Archetype.default)
            .joins(:_custom_fields)
            .where(topic_custom_fields: { name: GROUP_FIELD, value: group["id"] })
            .joins(:first_post)
            .where(
              posts: {
                hidden: false,
                user_deleted: false,
                deleted_at: nil,
                post_type: Post.types[:regular],
              },
            )
            .order(created_at: :desc, id: :desc)
        topics = scope.offset(page * limit).limit(limit + 1).to_a
        more = topics.length > limit
        topics = topics.first(limit)
      end
      render json: {
               resources: topics.filter_map { |topic| IsbfLibrary.resource(topic, guardian) },
               has_more: !!more,
             }
    end

    private

    def resource_library
      IsbfLibrary
    end

    def deletion_kind
      request.path.include?("/categories/") ? "grade" : "course"
    end

    def create_directory(kind)
      IsbfLibrary.ensure_can_submit!(current_user, guardian)
      RateLimiter.new(current_user, "isbf-library-catalog", 10, 1.minute).performed!
      attributes = {
        kind: kind,
        name: params[:name],
        category_id: kind == "group" ? params[:category_id] : nil,
      }
      if IsbfLibrary.can_manage?(guardian) ||
           (
             current_user.staff? &&
               !(
                 SiteSetting.respond_to?(:academy_roles_enabled?) &&
                   SiteSetting.academy_roles_enabled?
               )
           )
        entry = Catalog.create(current_user, **attributes)
        render json: { :success => true, :pending => false, kind => entry }
      else
        reviewable = Catalog.request(current_user, **attributes)
        render json: { success: true, pending: true, reviewable_id: reviewable.id }
      end
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    rescue IsbfLearning::StorageError
      render_json_error(I18n.t("isbf_library.directory_storage_error"), status: 422)
    end

    def check_category
      category = Category.find_by(id: IsbfLibrary.category_id)
      unless IsbfLibrary.enabled? && category && guardian.can_see_category?(category)
        raise Discourse::InvalidAccess
      end
    end
  end
end
