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

    it "uses the existing campus permission for direct publication, resource editing, course and parent editing" do
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
      put "/isbf/learning/courses/#{course["id"]}.json",
          params: {
            name: "有权限的课程修改",
            grade: 2
          }
      expect(response.status).to eq(200), response.body
      put "/isbf/learning/grades/2.json", params: { name: "有权限的上级分类" }
      expect(response.status).to eq(200), response.body
      SiteSetting.academy_moderators_manage_resources = false
      SiteSetting.academy_moderators_review_resources = true
      put "/isbf/learning/resources/#{resource["id"]}.json",
          params: {
            title: "Blocked after management permission revoked"
          }
      expect(response.status).to eq(403)
      put "/isbf/learning/courses/#{course["id"]}.json",
          params: {
            name: "权限关闭后的修改",
            grade: 1
          }
      expect(response.status).to eq(403)
      put "/isbf/learning/grades/2.json", params: { name: "权限关闭后的分类" }
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
end
