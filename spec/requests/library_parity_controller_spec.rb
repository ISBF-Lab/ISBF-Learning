# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfLibrary::LibraryController, type: :request do
  fab!(:category)
  fab!(:learning_category, :category)
  fab!(:admin)
  fab!(:member) { Fabricate(:user, active: true, approved: true, refresh_auto_groups: true) }

  let(:directory) { IsbfLibrary::Catalog.create(admin, kind: "category", name: "校园资料") }
  let(:group) do
    IsbfLibrary::Catalog.create(
      admin,
      kind: "group",
      name: "入学指南",
      category_id: directory.fetch("id"),
    )
  end

  before do
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = learning_category.id
    SiteSetting.isbf_library_enabled = true
    SiteSetting.isbf_library_category_id = category.id
    [category, learning_category].each do |resource_category|
      resource_category.set_permissions(trust_level_0: :full, staff: :full)
      resource_category.save!
    end
  end

  describe "#update_collection_form" do
    it "saves an independent audited library destination and preserves the course form" do
      original = SiteSetting.isbf_learning_collection_form_url
      expect(SiteSetting.isbf_library_collection_form_url).to eq(original)
      sign_in(admin)
      put "/isbf/library/collection-form.json", params: { url: "https://example.edu/library" }
      expect(response.status).to eq(200), response.body
      expect(SiteSetting.isbf_library_collection_form_url).to eq("https://example.edu/library")
      expect(SiteSetting.isbf_learning_collection_form_url).to eq(original)
      expect(
        UserHistory.where(acting_user_id: admin.id, subject: "isbf_library_collection_form_url"),
      ).to exist
    end

    it "rejects ordinary users and invalid destinations without changing either setting" do
      original = SiteSetting.isbf_library_collection_form_url
      sign_in(member)
      put "/isbf/library/collection-form.json", params: { url: "https://example.edu/library" }
      expect(response.status).to eq(403), response.body
      sign_in(admin)
      put "/isbf/library/collection-form.json", params: { url: "javascript:alert(1)" }
      expect(response.status).to eq(422), response.body
      expect(SiteSetting.isbf_library_collection_form_url).to eq(original)
    end
  end

  describe "#update_resource" do
    it "keeps library identity and authorship while editing resource metadata" do
      sign_in(admin)
      post "/isbf/library/resources.json",
           params: {
             group_id: group.fetch("id"),
             title: "Library onboarding reference",
             link: "https://example.edu/guide.pdf",
           }
      expect(response.status).to eq(200), response.body
      topic = Topic.find(response.parsed_body.fetch("resource").fetch("id"))
      put "/isbf/library/resources/#{topic.id}.json",
          params: {
            title: "Updated library onboarding reference",
            description: "A revised guide",
            contributor: "资料小组",
          }
      expect(response.status).to eq(200), response.body
      expect(topic.reload.title).to eq("Updated library onboarding reference")
      expect(topic.custom_fields).to include(
        IsbfLibrary::GROUP_FIELD => group.fetch("id"),
        IsbfLibrary::DESCRIPTION_FIELD => "A revised guide",
      )
      expect(topic.custom_fields.keys.grep(/\Aisbf_learning_/)).to be_empty
      expect(topic.first_post.user_id).to eq(admin.id)
      sign_in(member)
      put "/isbf/library/resources/#{topic.id}.json",
          params: {
            title: "Unauthorized resource update",
          }
      expect(response.status).to eq(403), response.body
    end
  end

  describe "#contributions" do
    it "lists the current account's published library contributions independently of courses" do
      sign_in(member)
      post "/isbf/library/resources.json",
           params: {
             group_id: group.fetch("id"),
             title: "Member library onboarding reference",
             link: "https://example.edu/member.pdf",
           }
      expect(response.status).to eq(200), response.body
      reviewable = ReviewableQueuedPost.order(:id).last
      result = reviewable.perform(admin, :approve_post)
      expect(result.success?).to eq(true)
      get "/isbf/library/contributions.json"
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("resources").map { |resource| resource.fetch("id") }).to eq(
        [result.created_post.topic_id],
      )
      get "/isbf/learning/contributions.json"
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("resources")).to be_empty
    end
  end

  describe "#destroy_directory" do
    it "requires a fresh confirmation and archives only the selected library group" do
      sign_in(admin)
      group_id = group.fetch("id")
      put "/isbf/library/groups/#{group_id}.json",
          params: {
            name: "更新的指南",
            grade: directory.fetch("id"),
          }
      expect(response.status).to eq(200), response.body
      get "/isbf/library/groups/#{group_id}/deletion-plan.json"
      expect(response.status).to eq(200), response.body
      plan = response.parsed_body
      delete "/isbf/library/groups/#{group_id}.json",
             params: {
               confirmation_token: "invalid",
               confirmation_count: 2,
             }
      expect(response.status).to eq(409), response.body
      expect(IsbfLibrary::Catalog.find_group(group_id)).to be_present
      delete "/isbf/library/groups/#{group_id}.json",
             params: {
               confirmation_token: plan.fetch("confirmation_token"),
               confirmation_count: plan.fetch("required_confirmations"),
               cascade: plan.fetch("has_children"),
             }
      expect(response.status).to eq(200), response.body
      expect(IsbfLibrary::Catalog.find_group(group_id)).to be_nil
      expect(
        IsbfLibrary::Catalog
          .groups(nil, include_deleted: true)
          .find { |entry| entry["id"] == group_id }
          .fetch("deleted_at"),
      ).to be_present
      expect(IsbfLibrary::Catalog.find_category(directory.fetch("id"))).to be_present
    end
  end
end
