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
    skip_before_action :preload_json, only: :download
    skip_before_action :check_xhr, only: :download

    def page
      render html: "".html_safe, layout: "application"
    end

    def courses
      render json: { courses: resource_catalog.list, grades: resource_catalog.grades }
    end

    def update_collection_form
      raise Discourse::InvalidAccess unless resource_library.can_manage?(guardian)
      url = params[:url].is_a?(String) ? params[:url].strip : ""
      SiteSetting.set_and_log(collection_setting, url, current_user)
      render json: { success: true, url: SiteSetting.public_send(collection_setting) }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    def update_course
      course =
        resource_catalog.update(
          current_user,
          params[:id],
          name: params[:name],
          grade: params[:grade],
        )
      render json: { success: true, pending: false, course: course }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    rescue StorageError
      render_json_error(I18n.t("isbf_learning.course_storage_error"), status: 422)
    end

    def deletion_plan
      render json:
               resource_library::DirectoryDeletion.plan(
                 current_user,
                 kind: deletion_kind,
                 id: params[:id],
               )
    end

    def destroy_directory
      render json:
               resource_library::DirectoryDeletion.delete(
                 current_user,
                 kind: deletion_kind,
                 id: params[:id],
                 confirmation_token: params[:confirmation_token],
                 confirmation_count: params[:confirmation_count],
                 cascade: params[:cascade],
               )
    rescue DirectoryDeletion::Changed
      render_json_error(I18n.t("isbf_learning.directory_changed"), status: 409)
    rescue StorageError
      render_json_error(I18n.t("isbf_learning.directory_delete_failed"), status: 422)
    end

    def update_grade
      grade = resource_catalog.update_grade(current_user, id: params[:id], name: params[:name])
      render json: { success: true, pending: false, grade: grade }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    rescue StorageError
      render_json_error(I18n.t("isbf_learning.course_storage_error"), status: 422)
    end

    def contributions
      page = params[:page].presence || "0"
      raise Discourse::InvalidParameters.new("page") unless page.to_s.match?(/\A\d{1,4}\z/)
      render json:
               Contributions.list(
                 current_user,
                 guardian,
                 page: page.to_i,
                 library: resource_library,
               )
    end

    def contributor_users
      raise Discourse::InvalidAccess unless resource_library.can_manage?(guardian)
      RateLimiter.new(current_user, "isbf-learning-contributor-lookup", 30, 1.minute).performed!
      users = resource_library.contributor_users(params[:student_number]).limit(10)
      render json: {
               users:
                 users.map { |user|
                   {
                     id: user.id,
                     username: user.username,
                     name: user.name,
                     avatar_template: user.avatar_template,
                   }
                 },
             }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    def create_course
      RateLimiter.new(current_user, "isbf-learning-courses", 10, 1.minute).performed!
      resource_library.ensure_can_submit!(current_user, guardian)
      if resource_library.can_manage?(guardian) ||
           (
             current_user.staff? &&
               !(
                 SiteSetting.respond_to?(:academy_roles_enabled?) &&
                   SiteSetting.academy_roles_enabled?
               )
           )
        course = resource_catalog.create(current_user, name: params[:name], grade: params[:grade])
        render json: { success: true, pending: false, course: course }
      else
        reviewable =
          resource_catalog.request(current_user, name: params[:name], grade: params[:grade])
        render json: { success: true, pending: true, reviewable_id: reviewable.id }
      end
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    rescue StorageError
      render_json_error(I18n.t("isbf_learning.course_storage_error"), status: 422)
    end

    def resources
      page = params[:page].presence || "0"
      raise Discourse::InvalidParameters.new("page") unless page.to_s.match?(/\A\d{1,4}\z/)
      page = page.to_i
      query = params[:q].to_s.strip
      if query.present?
        raise Discourse::InvalidParameters.new("q") if query.length > 200
        RateLimiter.new(current_user, "isbf-learning-search", 30, 1.minute).performed!
        results =
          Search.new(
            "#{query} isbf-learning:library in:first",
            guardian: guardian,
            search_type: :full_page,
            type_filter: "topic",
            page: page + 1,
            search_context: Category.find(resource_library.category_id),
          ).execute
        raise Discourse::InvalidParameters.new("q") if results.error
        topics = results.posts.map(&:topic).uniq(&:id)
        more = results.more_full_page_results || results.more_posts
      else
        course = resource_catalog.find(params[:course_id])
        raise Discourse::InvalidParameters.new("course_id") unless course
        limit = 20
        scope =
          Topic
            .visible
            .secured(guardian)
            .where(category_id: resource_library.category_id, archetype: Archetype.default)
            .joins(:_custom_fields)
            .where(
              topic_custom_fields: {
                name: resource_library::GROUP_FIELD,
                value: course["id"],
              },
            )
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
               resources: topics.filter_map { |topic| resource_library.resource(topic, guardian) },
               has_more: !!more,
             }
    end

    def create_resource
      resource_library.ensure_can_submit!(current_user, guardian)
      RateLimiter.new(current_user, "isbf-learning-share", 10, 1.minute).performed!
      link = resource_library.external_link(params[:link])
      title = params[:title].is_a?(String) ? params[:title].strip : ""
      introduction = resource_library.description(params[:description])
      contributor = resource_library.contributor(params[:contributor], current_user)
      if params[:student_number].present? || params[:contributor_user_id].present?
        raise Discourse::InvalidAccess unless resource_library.can_manage?(guardian)
      end
      options = {
        :title => title,
        :raw => resource_library.link_body(title, link, introduction),
        :category => resource_library.category_id,
        :archetype => Archetype.default,
        resource_library::GROUP_FIELD.to_sym => params[resource_group_param],
        resource_library::FILES_FIELD.to_sym => "[]",
        resource_library::LINK_FIELD.to_sym => link,
        resource_library::DESCRIPTION_FIELD.to_sym => introduction,
        resource_library::CONTRIBUTOR_FIELD.to_sym => contributor,
        resource_library::STUDENT_NUMBER_FIELD.to_sym => params[:student_number],
        resource_library::CONTRIBUTOR_USER_FIELD.to_sym => params[:contributor_user_id],
      }
      resource_library.validate_payload!(current_user, options)
      creator = TopicCreator.new(current_user, guardian, options)
      return render_json_error(creator.errors.full_messages, status: 422) unless creator.valid?
      result = NewPostManager.new(current_user, options).perform
      return render_json_error(result.errors.full_messages, status: 422) unless result.success?
      render json: {
               success: true,
               pending: result.reviewable.present? && result.post.nil?,
               resource: result.post && resource_library.resource(result.post.topic, guardian),
             }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    def destroy_resource
      raise Discourse::InvalidAccess unless resource_library.can_manage?(guardian)
      unless params[:id].to_s.match?(/\A[1-9]\d{0,18}\z/)
        raise Discourse::InvalidParameters.new("id")
      end
      topic = Topic.includes(:first_post).find_by(id: params[:id])
      raise Discourse::NotFound unless topic && resource_library.resource(topic, guardian)
      guardian.ensure_can_delete!(topic)
      destroyer = PostDestroyer.new(current_user, topic.first_post)
      destroyer.destroy
      unless Topic.with_deleted.find_by(id: topic.id)&.deleted_at
        return(render_json_error(I18n.t("isbf_learning.delete_failed"), status: 422))
      end
      render json: { success: true }
    end

    def update_resource
      resource_library.ensure_can_submit!(current_user, guardian)
      raise Discourse::InvalidAccess unless resource_library.can_manage?(guardian)
      unless params[:id].to_s.match?(/\A[1-9]\d{0,18}\z/)
        raise Discourse::InvalidParameters.new("id")
      end
      topic = Topic.includes(:first_post).find_by(id: params[:id])
      raise Discourse::NotFound unless topic && resource_library.resource(topic, guardian)
      post = topic.first_post
      guardian.ensure_can_edit!(post)
      fields = {}
      if params.key?(:title)
        raise Discourse::InvalidParameters.new("title") unless params[:title].is_a?(String)
        fields[:title] = params[:title].strip
      end
      {
        resource_group_param => resource_library::GROUP_FIELD,
        :description => resource_library::DESCRIPTION_FIELD,
        :link => resource_library::LINK_FIELD,
        :contributor => resource_library::CONTRIBUTOR_FIELD,
        :student_number => resource_library::STUDENT_NUMBER_FIELD,
        :contributor_user_id => resource_library::CONTRIBUTOR_USER_FIELD,
      }.each do |parameter, field|
        fields[field.to_sym] = params[parameter] if params.key?(parameter)
      end
      fields[resource_library::DESCRIPTION_FIELD.to_sym] = resource_library.description(
        params[:description],
      ) if params.key?(:description)
      fields[resource_library::CONTRIBUTOR_FIELD.to_sym] = resource_library.contributor(
        params[:contributor],
        post.user,
      ) if params.key?(:contributor)
      if params.key?(:student_number) || params.key?(:contributor_user_id)
        number =
          (
            if params.key?(:student_number)
              params[:student_number]
            else
              topic.custom_fields[resource_library::STUDENT_NUMBER_FIELD]
            end
          )
        user_id =
          (
            if params.key?(:contributor_user_id)
              params[:contributor_user_id]
            else
              topic.custom_fields[resource_library::CONTRIBUTOR_USER_FIELD]
            end
          )
        normalized =
          resource_library.contribution_identity!(
            current_user,
            resource_library::STUDENT_NUMBER_FIELD.to_sym => number,
            resource_library::CONTRIBUTOR_USER_FIELD.to_sym => user_id,
          )
        fields[resource_library::STUDENT_NUMBER_FIELD.to_sym],
        fields[resource_library::CONTRIBUTOR_USER_FIELD.to_sym] =
          normalized
      end
      link =
        fields.fetch(
          resource_library::LINK_FIELD.to_sym,
          topic.custom_fields[resource_library::LINK_FIELD],
        )
      if link.present?
        title = fields.fetch(:title, topic.title)
        description =
          resource_library.description(
            fields.fetch(
              resource_library::DESCRIPTION_FIELD.to_sym,
              topic.custom_fields[resource_library::DESCRIPTION_FIELD],
            ),
          )
        fields[:raw] = resource_library.link_body(
          title,
          resource_library.external_link(link),
          description,
        )
        IsbfLearning
          .file_ids(topic.custom_fields[resource_library::FILES_FIELD] || [])
          .each do |id|
            file = Files.metadata(id)
            next unless file
            fields[:raw] += "\n\n#{resource_library.link_body(file[:name], file[:url])}"
          end
      end
      revised = PostRevisor.new(post, topic).revise!(current_user, fields)
      if !revised && post.errors.present?
        return render_json_error(post.errors.full_messages, status: 422)
      end
      render json: {
               success: true,
               pending: false,
               edited: true,
               resource: resource_library.resource(topic.reload, guardian),
             }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
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
      send_file info[:path],
                filename: info[:name],
                type: "application/octet-stream",
                disposition: "attachment"
    end

    private

    def resource_library
      IsbfLearning
    end

    def resource_catalog
      resource_library == IsbfLearning ? Courses : IsbfLibrary::Catalog
    end

    def resource_group_param
      resource_library == IsbfLearning ? :course_id : :group_id
    end

    def collection_setting
      if resource_library == IsbfLearning
        :isbf_learning_collection_form_url
      else
        :isbf_library_collection_form_url
      end
    end

    def deletion_kind
      request.path.include?("/grades/") ? "grade" : "course"
    end

    def check_category
      category = Category.find_by(id: resource_library.category_id)
      raise Discourse::InvalidAccess unless category && guardian.can_see_category?(category)
    end
  end
end
