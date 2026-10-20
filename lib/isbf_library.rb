# frozen_string_literal: true

module IsbfLibrary
  def self.can_manage?(guardian)
    IsbfLearning.can_manage?(guardian)
  end

  def self.can_review?(guardian)
    IsbfLearning.can_review?(guardian)
  end

  STORE = "isbf-library"
  GROUP_FIELD = "isbf_library_group_id"
  FILES_FIELD = "isbf_library_files"
  LINK_FIELD = "isbf_library_link"
  DESCRIPTION_FIELD = "isbf_library_description"
  CONTRIBUTOR_FIELD = "isbf_library_contributor"
  STUDENT_NUMBER_FIELD = "isbf_library_student_number"
  CONTRIBUTOR_USER_FIELD = "isbf_library_contributor_user_id"
  RESOURCE_FIELDS = [
    GROUP_FIELD,
    FILES_FIELD,
    LINK_FIELD,
    DESCRIPTION_FIELD,
    CONTRIBUTOR_FIELD,
    STUDENT_NUMBER_FIELD,
    CONTRIBUTOR_USER_FIELD,
  ].freeze

  def self.external_link(value)
    IsbfLearning.external_link(value)
  end

  def self.description(value)
    IsbfLearning.description(value)
  end

  def self.contributor(value, user)
    IsbfLearning.contributor(value, user)
  end

  def self.contributor_users(value)
    IsbfLearning.contributor_users(value)
  end

  def self.link_body(title, link, introduction = "")
    IsbfLearning.link_body(title, link, introduction)
  end

  def self.contribution_identity!(actor, options)
    IsbfLearning.contribution_identity!(
      actor,
      {
        IsbfLearning::STUDENT_NUMBER_FIELD.to_sym => options[STUDENT_NUMBER_FIELD.to_sym],
        IsbfLearning::CONTRIBUTOR_USER_FIELD.to_sym => options[CONTRIBUTOR_USER_FIELD.to_sym],
      },
    )
  end

  def self.category_id
    id = SiteSetting.isbf_library_category_id.to_i
    if id.positive? && id != SiteSetting.isbf_learning_category_id.to_i && Category.exists?(id: id)
      id
    end
  end

  def self.enabled?
    SiteSetting.isbf_learning_enabled && SiteSetting.isbf_library_enabled && category_id.present?
  end

  def self.learning_topic?(topic)
    category_id && topic&.category_id == category_id && !topic.private_message?
  end

  def self.ensure_can_submit!(user, guardian)
    category = Category.find_by(id: category_id)
    permitted =
      enabled? && user&.active? && (user.staff? || user.approved?) && !user.silenced? &&
        !user.suspended? && category && guardian.can_create_topic_on_category?(category)
    raise Discourse::InvalidAccess unless permitted
  end

  def self.file_ids(value)
    ids = value.is_a?(String) ? JSON.parse(value) : value
    raise Discourse::InvalidParameters.new(FILES_FIELD) unless ids == []
    ids
  rescue JSON::ParserError
    raise Discourse::InvalidParameters.new(FILES_FIELD)
  end

  def self.validate_payload!(user, options, contributor_user: user)
    ensure_can_submit!(user, user.guardian)
    IsbfLearning.ensure_scope_fields!(self, options)
    IsbfLearning.description(options[DESCRIPTION_FIELD.to_sym])
    IsbfLearning.contributor(options[CONTRIBUTOR_FIELD.to_sym], contributor_user)
    if options[STUDENT_NUMBER_FIELD.to_sym].present? ||
         options[CONTRIBUTOR_USER_FIELD.to_sym].present?
      raise Discourse::InvalidAccess unless can_manage?(user.guardian)
      contribution_identity!(user, options)
    end
    group = Catalog.find_group(options[GROUP_FIELD.to_sym])
    ids = file_ids(options[FILES_FIELD.to_sym])
    raw = options[:raw].to_s
    link = IsbfLearning.external_link(options[LINK_FIELD.to_sym])
    unless group && Catalog.find_category(group["category_id"]) &&
             options[:category].to_i == category_id && options[:title].to_s.strip.present? &&
             !options[:title].to_s.include?("[isbf-untitled:") &&
             options[:archetype] != Archetype.private_message && !options[:isbf_anonymous] &&
             !raw.match?(%r{(?:upload://|/uploads/|/isbf/learning/files/)}i) && raw.include?(link)
      raise Discourse::InvalidParameters.new(I18n.t("isbf_library.invalid"))
    end
    [group, ids]
  end

  def self.visible_resource?(topic, guardian)
    unless guardian.user && learning_topic?(topic) && topic.visible && !topic.deleted_at &&
             guardian.can_see_topic?(topic)
      return false
    end
    post = topic.first_post
    post && post.post_type == Post.types[:regular] && !post.deleted_at && !post.user_deleted &&
      !post.hidden? && guardian.can_see_post?(post) &&
      !(defined?(IsbfModeration::Hold) && IsbfModeration::Hold.persisted?(post))
  end

  def self.resource(topic, guardian, courses: nil)
    group = Catalog.find_group(topic.custom_fields[GROUP_FIELD])
    category = group && Catalog.find_category(group["category_id"])
    return unless category && visible_resource?(topic, guardian)
    link = topic.custom_fields[LINK_FIELD].presence
    return unless link
    post = topic.first_post
    data = {
      id: topic.id,
      title: topic.title,
      url: topic.relative_url,
      description: IsbfLearning.description(topic.custom_fields[DESCRIPTION_FIELD]),
      created_at: post.created_at,
      category: category,
      group: group,
      contributor:
        topic.custom_fields[CONTRIBUTOR_FIELD].presence || IsbfLearning.contributor_name(post.user),
      can_delete: can_manage?(guardian) && guardian.can_delete_topic?(topic),
      can_edit: can_manage?(guardian) && guardian.can_edit_post?(post),
      author:
        post.user &&
          {
            username: post.user.username,
            name: post.user.name,
            avatar_template: post.user.avatar_template,
          },
      files: [],
      links: [IsbfLearning.external_link(link)],
      link_only: true,
    }
    if can_manage?(guardian)
      data[:student_number] = topic.custom_fields[STUDENT_NUMBER_FIELD] || ""
      data[:contributor_user_id] = topic.custom_fields[CONTRIBUTOR_USER_FIELD].presence&.to_i
    end
    data
  end
end

require_relative "isbf_library/catalog"

require_relative "isbf_library/directory_deletion"
