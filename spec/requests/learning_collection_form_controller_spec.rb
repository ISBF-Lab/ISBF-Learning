# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfLearning::LibraryController, type: :request do
  fab!(:category)
  fab!(:admin)
  fab!(:user)
  fab!(:moderator)

  before do
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  describe "#update_collection_form" do
    it "keeps the existing collection URL by default and blocks anonymous and ordinary users" do
      original = SiteSetting.isbf_learning_collection_form_url
      expect(original).to eq("https://f.wps.cn/g/wG6gL3Rz/")
      put "/isbf/learning/collection-form.json",
          params: {
            url: "https://example.org/form"
          }
      expect(response.status).to eq(403)
      sign_in(user)
      put "/isbf/learning/collection-form.json",
          params: {
            url: "https://example.org/form"
          }
      expect(response.status).to eq(403)
      expect(SiteSetting.isbf_learning_collection_form_url).to eq(original)
    end

    it "lets administrators save another domain and records the setting change" do
      sign_in(admin)
      url = "http://example.edu/learning?year=2026#submit"
      put "/isbf/learning/collection-form.json", params: { url: " #{url} " }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body).to include("success" => true, "url" => url)
      expect(SiteSetting.isbf_learning_collection_form_url).to eq(url)
      expect(
        UserHistory.where(
          acting_user_id: admin.id,
          subject: "isbf_learning_collection_form_url"
        ).count
      ).to eq(1)
    end

    it "uses the existing management grant independently of review and rechecks revocation" do
      unless defined?(DiscourseAcademyRoles::ModeratorPermissions)
        skip "Academy integration is not installed"
      end
      SiteSetting.academy_official_group = Fabricate(:group).id
      SiteSetting.academy_official_category = Fabricate(:category).id
      SiteSetting.academy_roles_enabled = true
      SiteSetting.academy_moderators_manage_resources = true
      SiteSetting.academy_moderators_review_resources = false
      sign_in(moderator)
      put "/isbf/learning/collection-form.json",
          params: {
            url: "https://example.edu/resources"
          }
      expect(response.status).to eq(200), response.body
      SiteSetting.academy_moderators_manage_resources = false
      SiteSetting.academy_moderators_review_resources = true
      put "/isbf/learning/collection-form.json",
          params: {
            url: "https://example.edu/other"
          }
      expect(response.status).to eq(403)
      expect(SiteSetting.isbf_learning_collection_form_url).to eq(
        "https://example.edu/resources"
      )
    end

    it "rejects invalid links without replacing the saved destination" do
      sign_in(admin)
      original = SiteSetting.isbf_learning_collection_form_url
      [
        nil,
        "",
        "not a link",
        "/relative",
        "javascript:alert(1)",
        "ftp://example.org/form",
        "https://"
      ].each do |url|
        put "/isbf/learning/collection-form.json", params: { url: url }
        expect(response.status).to eq(422), response.body
        expect(SiteSetting.isbf_learning_collection_form_url).to eq(original)
      end
    end

    it "also validates updates from the native site settings interface" do
      expect {
        SiteSetting.isbf_learning_collection_form_url = "javascript:alert(1)"
      }.to raise_error(Discourse::InvalidParameters)
      SiteSetting.isbf_learning_collection_form_url =
        "https://forms.example.edu/collection"
      expect(SiteSetting.isbf_learning_collection_form_url).to eq(
        "https://forms.example.edu/collection"
      )
    end
  end
end
