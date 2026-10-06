# frozen_string_literal: true

module IsbfLearning
  class Engine < ::Rails::Engine
    engine_name "isbf-learning"
    isolate_namespace IsbfLearning
  end

  class LibraryController < ::ApplicationController
    wrap_parameters false
    requires_login
    requires_plugin "isbf-learning"
    before_action :check_category

    def page
      render html: "".html_safe, layout: "application"
    end

    def courses
      render json: { courses: Courses.list }
    end

    def create_course
      RateLimiter.new(current_user, "isbf-learning-courses", 10, 1.minute).performed!
      render json: { course: Courses.create(current_user, name: params[:name], grade: params[:grade]) }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    def resources
      page = params[:page].presence || "0"
      raise Discourse::InvalidParameters.new("page") unless page.to_s.match?(/\A\d{1,4}\z/)
      page = page.to_i
      query = params[:q].to_s.strip
      if query.present?
        raise Discourse::InvalidParameters.new("q") if query.length > 200
        RateLimiter.new(current_user, "isbf-learning-search", 30, 1.minute).performed!
        results = Search.new(
          "#{query} isbf-learning:library in:first",
          guardian: guardian, search_type: :full_page, type_filter: "topic", page: page + 1,
          search_context: Category.find(IsbfLearning.category_id),
        ).execute
        raise Discourse::InvalidParameters.new("q") if results.error
        topics = results.posts.map(&:topic).uniq(&:id)
        more = results.more_full_page_results || results.more_posts
      else
        course = Courses.find(params[:course_id])
        raise Discourse::InvalidParameters.new("course_id") unless course
        limit = 20
        scope = Topic.visible.secured(guardian).where(category_id: IsbfLearning.category_id, archetype: Archetype.default)
          .joins(:_custom_fields).where(topic_custom_fields: { name: COURSE_FIELD, value: course["id"] })
          .joins(:first_post).where(posts: { hidden: false, user_deleted: false, deleted_at: nil, post_type: Post.types[:regular] })
          .order(created_at: :desc, id: :desc)
        topics = scope.offset(page * limit).limit(limit + 1).to_a
        more = topics.length > limit
        topics = topics.first(limit)
      end
      render json: { resources: topics.filter_map { |topic| IsbfLearning.resource(topic, guardian) }, has_more: !!more }
    end

    def upload
      render json: Files.upload(current_user, guardian, params[:file] || params[:files]&.first)
    rescue StorageError => error
      render_json_error(I18n.t("isbf_learning.storage_error"), status: 422)
    end

    def download
      info = Files.download(params[:id], current_user, guardian)
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_file info[:path], filename: info[:name], type: "application/octet-stream", disposition: "attachment"
    end

    private

    def check_category
      category = Category.find_by(id: IsbfLearning.category_id)
      raise Discourse::InvalidAccess unless category && guardian.can_see_category?(category)
    end
  end
end
