# frozen_string_literal: true

# name: isbf-learning
# about: Authenticated learning resources with native moderation and private files.
# version: 0.1.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Learning
# required_version: 3.2.0

enabled_site_setting :isbf_learning_enabled

after_initialize do
  require_relative "lib/isbf_learning"
  require_relative "lib/isbf_learning/controllers"

  { IsbfLearning::COURSE_FIELD => :string, IsbfLearning::FILES_FIELD => :json }.each do |field, type|
    register_topic_custom_field_type(field, type, max_length: 4096)
    add_permitted_post_create_param(field.to_sym, :string)
    NewPostManager.add_plugin_payload_attribute(field.to_sym)
    add_permitted_post_update_param(field.to_sym)
    PostRevisor.track_topic_field(field.to_sym) do |changes, value|
      next if value.nil?
      unless changes.user.staff? && IsbfLearning.learning_topic?(changes.topic)
        raise Discourse::InvalidAccess
      end
      normalized = field == IsbfLearning::FILES_FIELD ? IsbfLearning.file_ids(value) : value.to_s
      if field == IsbfLearning::COURSE_FIELD && !IsbfLearning::Courses.find(normalized)
        raise Discourse::InvalidParameters.new(field)
      end
      changes.record_change(field, changes.topic.custom_fields[field], normalized)
      changes.topic.custom_fields[field] = normalized
    end
    %i[topic_view post].each do |serializer|
      add_to_serializer(serializer, field.to_sym, include_condition: -> { scope.user.present? }) do
        topic = object.respond_to?(:topic) ? object.topic : object
        topic.custom_fields[field] if IsbfLearning.learning_topic?(topic)
      end
    end
  end

  module ::IsbfLearning::ResourceGuardian
    def can_create_topic_on_category?(category)
      id = category.is_a?(Category) ? category.id : category
      return super unless IsbfLearning.category_id && id.to_i == IsbfLearning.category_id
      SiteSetting.isbf_learning_enabled && user&.active? && (user.staff? || user.approved?) &&
        !user.silenced? && !user.suspended? &&
        (is_admin? || Category.topic_create_allowed(self).exists?(id: id))
    end

    def can_see_topic?(topic, hide_deleted = true)
      return false if IsbfLearning.learning_topic?(topic) && !user
      super
    end

    def can_edit_post?(post)
      return false if post&.is_first_post? && IsbfLearning.learning_topic?(post.topic) && !is_staff?
      super
    end

    def can_edit_topic?(topic)
      return false if IsbfLearning.learning_topic?(topic) && !is_staff?
      super
    end
  end
  Guardian.prepend(IsbfLearning::ResourceGuardian)

  on(:before_upload_creation) do |_file, image, upload, _validate|
    id = File.basename(upload.original_filename.to_s, File.extname(upload.original_filename.to_s))
    if image && IsbfLearning::Files.valid_id?(id) && IsbfLearning::Files.metadata(id)
      upload.errors.add(:base, I18n.t("isbf_learning.invalid"))
    end
  end

  module ::IsbfLearning::ResourceRevisor
    def revise!(editor, fields, opts = {}, &block)
      if IsbfLearning.learning_topic?(@post.topic) && @post.is_first_post?
        raise Discourse::InvalidAccess unless editor.staff?
        payload = {
          title: fields[:title] || @post.topic.title,
          raw: fields[:raw] || @post.raw,
          category: fields[:category_id] || @post.topic.category_id,
          isbf_learning_course_id: fields[IsbfLearning::COURSE_FIELD.to_sym] || @post.topic.custom_fields[IsbfLearning::COURSE_FIELD],
          isbf_learning_files: fields[IsbfLearning::FILES_FIELD.to_sym] || @post.topic.custom_fields[IsbfLearning::FILES_FIELD],
        }
        raise Discourse::InvalidParameters.new("category_id") unless payload[:category].to_i == IsbfLearning.category_id
        IsbfLearning.validate_payload!(editor, payload)
      elsif fields.any? { |key, value| [IsbfLearning::COURSE_FIELD, IsbfLearning::FILES_FIELD].include?(key.to_s) && !value.nil? }
        raise Discourse::InvalidParameters.new("isbf_learning")
      end
      fields = fields.reject do |key, value|
        value.nil? && [IsbfLearning::COURSE_FIELD, IsbfLearning::FILES_FIELD].include?(key.to_s)
      end
      PluginStoreRow.transaction do
        result = super(editor, fields, opts, &block)
        if result && IsbfLearning.learning_topic?(@post.topic) && @post.is_first_post?
          IsbfLearning.file_ids(@post.topic.custom_fields[IsbfLearning::FILES_FIELD] || []).each do |id|
            IsbfLearning::Files.mark_bound!(id)
          end
        end
        result
      end
    end
  end
  PostRevisor.prepend(IsbfLearning::ResourceRevisor)

  NewPostManager.add_handler(-100) do |manager|
    fields = [IsbfLearning::COURSE_FIELD, IsbfLearning::FILES_FIELD]
    supplied = fields.any? { |field| manager.args[field.to_sym].present? }
    resource = manager.args[:category].to_i == IsbfLearning.category_id && manager.args[:topic_id].blank?
    next unless supplied || resource
    begin
      raise Discourse::InvalidParameters.new("isbf_learning") unless resource
      IsbfLearning.validate_payload!(manager.user, manager.args)
      unless manager.user.staff?
        post = Post.new(raw: manager.args[:raw], user: manager.user, post_number: 1)
        PostValidator.new(skip_topic: true).validate(post)
        if post.errors.present?
          result = NewPostResult.new(:created_post, false)
          result.errors.add(:base, post.errors.full_messages)
          next result
        end
        manager.enqueue(:category)
      end
    rescue Discourse::InvalidParameters, Discourse::InvalidAccess => error
      result = NewPostResult.new(:create_post, false)
      result.errors.add(:base, I18n.t("isbf_learning.invalid"))
      result
    end
  end

  on(:before_create_post) do |post, options|
    next if post.user&.is_system_user?
    supplied = [IsbfLearning::COURSE_FIELD, IsbfLearning::FILES_FIELD].any? { |field| options[field.to_sym].present? }
    resource = options[:category].to_i == IsbfLearning.category_id && options[:topic_id].blank?
    next unless supplied || resource
    raise Discourse::InvalidParameters.new("isbf_learning") unless resource
    IsbfLearning.validate_payload!(post.user, options)
  end

  on(:before_create_topic) do |topic, creator|
    next if creator.user.is_system_user?
    supplied = [IsbfLearning::COURSE_FIELD, IsbfLearning::FILES_FIELD].any? { |field| creator.opts[field.to_sym].present? }
    next unless supplied || IsbfLearning.learning_topic?(topic)
    raise Discourse::InvalidParameters.new("isbf_learning") unless IsbfLearning.learning_topic?(topic)
    unless creator.user.staff? || creator.opts[:reviewed_queued_post]
      raise Discourse::InvalidAccess
    end
    course, files = IsbfLearning.validate_payload!(creator.user, creator.opts)
    topic.custom_fields[IsbfLearning::COURSE_FIELD] = course["id"]
    topic.custom_fields[IsbfLearning::FILES_FIELD] = files
    files.each { |id| IsbfLearning::Files.mark_bound!(id) }
  end

  add_to_serializer(:site, :isbf_learning, include_condition: -> { SiteSetting.isbf_learning_enabled && IsbfLearning.category_id }) do
    { category_id: IsbfLearning.category_id, grades: IsbfLearning::GRADES }
  end

  register_search_advanced_filter(/\Aisbf-learning:library\z/) do |posts, _|
    id = IsbfLearning.category_id
    id ? posts.where(post_number: 1, topics: { category_id: id, visible: true, archetype: Archetype.default }) : posts.none
  end

  IsbfLearning::Engine.routes.draw do
    get "/" => "library#page"
    get "/courses" => "library#courses"
    post "/courses" => "library#create_course"
    get "/resources" => "library#resources"
    post "/uploads" => "library#upload"
    get "/files/:id" => "library#download"
  end
  Discourse::Application.routes.append do
    mount ::IsbfLearning::Engine, at: "/isbf/learning"
  end
end
