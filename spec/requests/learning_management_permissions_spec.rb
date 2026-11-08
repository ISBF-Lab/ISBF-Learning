# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfLearning::LibraryController, type: :request do
  fab!(:category)
  fab!(:admin)
  fab!(:official_group, :group)
  fab!(:official_category, :category)
  fab!(:moderator) do
    Fabricate(
      :moderator,
      active: true,
      approved: true,
      refresh_auto_groups: true
    )
  end

  before do
    unless defined?(DiscourseAcademyRoles::ModeratorPermissions)
      skip "Academy permissions integration is provided by the installed academy plugin"
    end
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_official_category = official_category.id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  describe "resource management permission" do
    it "validates a selected registered student and immediately reflects reassignment and deletion" do
      course = IsbfLearning::Courses.create(admin, name: "贡献归属测试", grade: 1)
      student =
        Fabricate(
          :user,
          active: true,
          approved: true,
          refresh_auto_groups: true
        )
      another_student =
        Fabricate(
          :user,
          active: true,
          approved: true,
          refresh_auto_groups: true
        )
      [student, another_student].each_with_index do |user, index|
        DiscourseAcademyRoles::StudentRegistration.create!(
          invite: Fabricate(:invite, invited_by: admin, email: nil),
          issued_by: admin,
          student_number: "2026000#{index + 1}",
          user: user,
          registered_at: Time.now.utc
        )
      end
      sign_in(admin)
      get "/isbf/learning/contributor-users.json",
          params: {
            student_number: "20260001"
          }
      expect(response.status).to eq(200), response.body
      expect(
        response.parsed_body.fetch("users").map { |user| user.fetch("id") }
      ).to eq([student.id])
      post "/isbf/learning/resources.json",
           params: {
             course_id: course["id"],
             title: "Student identity contribution reference",
             link: "https://example.org/attributed",
             student_number: "20260001",
             contributor_user_id: student.id
           }
      expect(response.status).to eq(200), response.body
      resource_id = response.parsed_body.fetch("resource").fetch("id")
      sign_in(student)
      get "/isbf/learning/contributions.json"
      expect(
        response
          .parsed_body
          .fetch("resources")
          .map { |resource| resource.fetch("id") }
      ).to eq([resource_id])
      sign_in(admin)
      put "/isbf/learning/resources/#{resource_id}.json",
          params: {
            student_number: "20260002",
            contributor_user_id: another_student.id
          }
      expect(response.status).to eq(200), response.body
      sign_in(student)
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources")).to be_empty
      sign_in(another_student)
      get "/isbf/learning/contributions.json"
      expect(
        response
          .parsed_body
          .fetch("resources")
          .map { |resource| resource.fetch("id") }
      ).to eq([resource_id])
      sign_in(admin)
      delete "/isbf/learning/resources/#{resource_id}.json"
      expect(response.status).to eq(200), response.body
      sign_in(another_student)
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources")).to be_empty
    end

    it "uses the existing campus permission for direct publication and resource editing" do
      course = IsbfLearning::Courses.create(admin, name: "管理权限测试", grade: 1)
      SiteSetting.academy_moderators_manage_resources = true
      SiteSetting.approve_post_count = 10
      sign_in(moderator)
      post "/isbf/learning/resources.json",
           params: {
             course_id: course["id"],
             title: "Permission controlled course contribution",
             link: "https://example.org/managed"
           }
      expect(response.status).to eq(200), response.body
      resource = response.parsed_body.fetch("resource")
      expect(response.parsed_body.fetch("pending")).to eq(false)
      put "/isbf/learning/resources/#{resource["id"]}.json",
          params: {
            title: "Managed resource updated by delegated admin"
          }
      expect(response.status).to eq(200), response.body
      SiteSetting.academy_moderators_manage_resources = false
      SiteSetting.academy_moderators_review_resources = true
      put "/isbf/learning/resources/#{resource["id"]}.json",
          params: {
            title: "Blocked after management permission revoked"
          }
      expect(response.status).to eq(403)
      get "/isbf/learning/contributor-users.json",
          params: {
            student_number: "20260001"
          }
      expect(response.status).to eq(403)
      delete "/isbf/learning/resources/#{resource["id"]}.json"
      expect(response.status).to eq(403)
    end
  end

  describe "resource catalog management permission" do
    before do
      unless SiteSetting.respond_to?(:academy_moderators_manage_resource_catalogs?)
        skip "The installed academy plugin does not provide the resource catalog permission"
      end
      SiteSetting.academy_moderators_manage_resource_catalogs = false
      SiteSetting.academy_moderators_manage_resources = true
      sign_in(moderator)
    end

    it "authorizes learning category and course changes independently of resource management" do
      post "/isbf/learning/grades.json", params: { name: "通识课程" }
      expect(response.status).to eq(403)
      post "/isbf/learning/courses.json", params: { name: "待审核课程", grade: 1 }
      expect(response.parsed_body.fetch("pending")).to eq(true)

      SiteSetting.academy_moderators_manage_resources = false
      SiteSetting.academy_moderators_manage_resource_catalogs = true
      post "/isbf/learning/grades.json", params: { name: "通识课程" }
      expect(response.status).to eq(201), response.body
      grade_id = response.parsed_body.dig("grade", "id")
      post "/isbf/learning/courses.json", params: { name: "新增课程", grade: grade_id }
      expect(response.status).to eq(200), response.body
      course_id = response.parsed_body.dig("course", "id")
      put "/isbf/learning/courses/#{course_id}.json", params: { name: "移动课程", grade: 2 }
      expect(response.parsed_body.fetch("course")).to include("name" => "移动课程", "grade" => 2)
      put "/isbf/learning/grades/#{grade_id}.json", params: { name: "分类改名" }
      expect(response.parsed_body.dig("grade", "label")).to eq("分类改名")

      SiteSetting.academy_moderators_manage_resource_catalogs = false
      SiteSetting.academy_moderators_manage_resources = true
      put "/isbf/learning/courses/#{course_id}.json", params: { name: "越权修改", grade: 1 }
      expect(response.status).to eq(403)
      put "/isbf/learning/grades/#{grade_id}.json", params: { name: "越权修改" }
      expect(response.status).to eq(403)
    end

    it "manages library categories and groups with catalog permission alone" do
      library_category = Fabricate(:category)
      library_category.set_permissions(trust_level_0: :full, staff: :full)
      library_category.save!
      SiteSetting.isbf_library_enabled = true
      SiteSetting.isbf_library_category_id = library_category.id
      target = IsbfLibrary::Catalog.create(admin, kind: "category", name: "目标分类")

      post "/isbf/library/categories.json", params: { name: "待审核分类" }
      expect(response.parsed_body.fetch("pending")).to eq(true)
      library_category.set_permissions(trust_level_0: :readonly, staff: :full)
      library_category.save!
      SiteSetting.academy_moderators_manage_resources = false
      SiteSetting.academy_moderators_manage_resource_catalogs = true
      post "/isbf/library/categories.json", params: { name: "资料分类" }
      expect(response.status).to eq(200), response.body
      category_id = response.parsed_body.dig("category", "id")
      post "/isbf/library/groups.json", params: { name: "资料分组", category_id: category_id }
      expect(response.status).to eq(200), response.body
      group_id = response.parsed_body.dig("group", "id")
      put "/isbf/library/groups/#{group_id}.json", params: { name: "移动分组", grade: target["id"] }
      expect(response.parsed_body.fetch("course")).to include(
        "name" => "移动分组",
        "category_id" => target["id"],
      )
      put "/isbf/library/categories/#{category_id}.json", params: { name: "分类改名" }
      expect(response.parsed_body.dig("grade", "name")).to eq("分类改名")

      sign_in(admin)
      post "/isbf/library/resources.json",
           params: {
             group_id: group_id,
             title: "Library directory deletion reference",
             link: "https://example.org/directory",
           }
      expect(response.status).to eq(200), response.body
      topic_id = response.parsed_body.dig("resource", "id")

      sign_in(moderator)
      get "/isbf/library/categories/#{target["id"]}/deletion-plan.json"
      expect(response.status).to eq(200), response.body
      plan = response.parsed_body
      delete "/isbf/library/categories/#{target["id"]}.json",
             params: {
               confirmation_token: plan.fetch("confirmation_token"),
               confirmation_count: 3,
               cascade: true,
             }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("deleted_courses")).to eq([group_id])
      expect(Topic.with_deleted.find(topic_id).deleted_at).to be_present
    end
  end
end
