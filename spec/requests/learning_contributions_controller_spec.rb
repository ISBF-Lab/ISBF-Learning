# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfLearning::LibraryController, type: :request do
  fab!(:category)
  fab!(:admin)
  fab!(:member) { Fabricate(:user, active: true, approved: true, refresh_auto_groups: true) }
  fab!(:other) { Fabricate(:user, active: true, approved: true, refresh_auto_groups: true) }
  fab!(:moderator) do
    Fabricate(:moderator, active: true, approved: true, refresh_auto_groups: true)
  end

  let(:course) { IsbfLearning::Courses.create(admin, name: "微观经济学", grade: 1) }

  before do
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  def publish_resource(extra = {})
    @resource_number = (@resource_number || 0) + 1
    title = "Published course contribution reference"
    title = "#{title} #{@resource_number}" if @resource_number > 1
    sign_in(admin)
    post "/isbf/learning/resources.json",
         params: {
           course_id: course["id"],
           title: title,
           link: "https://example.org/contribution",
           contributor: "贡献者",
           description: "学习资料介绍",
         }.merge(extra)
    expect(response.status).to eq(200), response.body
    Topic.find(response.parsed_body.fetch("resource").fetch("id"))
  end

  describe "#contributions" do
    it "shows a submitted resource only after native approval and keeps rejected submissions out" do
      course_id = course["id"]
      sign_in(member)
      post "/isbf/learning/resources.json",
           params: {
             course_id: course_id,
             title: "Pending contribution course resource",
             link: "https://example.org/pending",
           }
      expect(response.status).to eq(200), response.body
      pending = ReviewableQueuedPost.order(:id).last
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources")).to be_empty
      expect(pending.perform(admin, :reject_post).success?).to eq(true)
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources")).to be_empty
      post "/isbf/learning/resources.json",
           params: {
             course_id: course_id,
             title: "Approved contribution course resource",
             link: "https://example.org/approved",
           }
      approved = ReviewableQueuedPost.order(:id).last.perform(admin, :approve_post)
      expect(approved.success?).to eq(true)
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources").map { |resource| resource.fetch("id") }).to eq(
        [approved.created_post.topic_id],
      )
    end

    it "returns only the current user's published attribution, excluding namesakes, hidden and deleted resources" do
      assigned = publish_resource
      assigned.custom_fields[IsbfLearning::CONTRIBUTOR_USER_FIELD] = member.id.to_s
      assigned.save_custom_fields
      namesake = publish_resource(contributor: member.username)
      deleted = publish_resource
      deleted.custom_fields[IsbfLearning::CONTRIBUTOR_USER_FIELD] = member.id.to_s
      deleted.save_custom_fields
      PostDestroyer.new(admin, deleted.first_post).destroy
      hidden = publish_resource
      hidden.custom_fields[IsbfLearning::CONTRIBUTOR_USER_FIELD] = member.id.to_s
      hidden.save_custom_fields
      hidden.first_post.update!(hidden: true)
      sign_in(member)
      get "/isbf/learning/contributions.json",
          params: {
            user_id: other.id,
            course_id: namesake.custom_fields[IsbfLearning::COURSE_FIELD],
          }
      expect(response.status).to eq(200)
      resources = response.parsed_body.fetch("resources")
      expect(resources.map { |resource| resource.fetch("id") }).to eq([assigned.id])
      expect(resources.first).to include(
        "title" => assigned.title,
        "description" => "学习资料介绍",
        "contributor" => "贡献者",
        "links" => ["https://example.org/contribution"],
      )
      expect(resources.first.fetch("created_at")).to be_present
      expect(resources.first.keys).not_to include("student_number", "contributor_user_id")
    end

    it "includes the actual uploader for historical unassigned resources and excludes reassigned uploads" do
      historical = publish_resource
      reassigned = publish_resource
      reassigned.custom_fields[IsbfLearning::CONTRIBUTOR_USER_FIELD] = member.id.to_s
      reassigned.save_custom_fields
      get "/isbf/learning/contributions.json"
      expect(response.parsed_body.fetch("resources").map { |resource| resource.fetch("id") }).to eq(
        [historical.id],
      )
    end

    it "rejects guests and malformed pagination" do
      get "/isbf/learning/contributions.json"
      expect(response.status).to eq(403)
      sign_in(member)
      get "/isbf/learning/contributions.json", params: { page: "-1" }
      expect(response.status).to eq(400)
    end
  end

  describe "#update_resource" do
    it "clears optional introduction and contributor inputs from FormKit" do
      resource = publish_resource
      put "/isbf/learning/resources/#{resource.id}.json",
          params: {
            description: nil,
            contributor: nil,
          }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("resource")).to include(
        "description" => "",
        "contributor" => "",
      )
    end

    it "keeps private attachments and their downloads when editing an older resource" do
      id = SecureRandom.uuid
      contents = "Private legacy course notes"
      path = IsbfLearning::Files.path(id)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      PluginStore.set(
        IsbfLearning::STORE,
        "file:#{id}",
        { name: "legacy-notes.txt", size: contents.bytesize, owner_id: admin.id, bound: false },
      )
      result =
        NewPostManager.new(
          admin,
          title: "Legacy attachment course reference",
          raw: "Private notes [legacy](/isbf/learning/files/#{id})",
          category: category.id,
          isbf_learning_course_id: course["id"],
          isbf_learning_files: [id].to_json,
        ).perform
      expect(result.success?).to eq(true), result.errors.full_messages.join(", ")
      sign_in(admin)
      put "/isbf/learning/resources/#{result.post.topic_id}.json",
          params: {
            title: "Updated legacy attachment reference",
            description: "附件资料介绍",
            link: "https://example.org/legacy-notes",
          }
      expect(response.status).to eq(200), response.body
      expect(
        response.parsed_body.fetch("resource").fetch("files").map { |file| file.fetch("id") },
      ).to eq([id])
      expect(result.post.reload.raw).to include("/isbf/learning/files/#{id}")
      sign_in(member)
      get "/isbf/learning/files/#{id}"
      expect(response.status).to eq(200), response.body
      expect(response.body).to eq(contents)
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    it "accepts an unchanged save without creating a false error" do
      resource = publish_resource
      put "/isbf/learning/resources/#{resource.id}.json", params: { title: resource.title }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("resource").fetch("id")).to eq(resource.id)
    end

    it "updates the displayed fields and course atomically without changing the native author" do
      resource = publish_resource
      next_course = IsbfLearning::Courses.create(admin, name: "管理学", grade: 2)
      put "/isbf/learning/resources/#{resource.id}.json",
          params: {
            title: "Updated published contribution reference",
            description: "新的简介",
            link: "https://example.org/changed",
            contributor: "新的贡献者",
            course_id: next_course["id"],
            student_number: "",
            contributor_user_id: "",
          }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("resource")).to include(
        "title" => "Updated published contribution reference",
        "description" => "新的简介",
        "contributor" => "新的贡献者",
        "grade" => 2,
      )
      expect(resource.reload.first_post.user_id).to eq(admin.id)
      expect(resource.first_post.raw).to include("https://example.org/changed")
    end

    it "denies ordinary users even when they know the resource id" do
      resource = publish_resource
      sign_in(member)
      put "/isbf/learning/resources/#{resource.id}.json",
          params: {
            title: "Unauthorized contribution update",
          }
      expect(response.status).to eq(403)
      expect(resource.reload.title).to eq("Published course contribution reference")
    end

    it "rejects a forged student association without changing the resource" do
      resource = publish_resource
      put "/isbf/learning/resources/#{resource.id}.json",
          params: {
            title: "Attempted invalid association change",
            student_number: "does-not-exist",
            contributor_user_id: member.id,
          }
      expect(response.status).to eq(422), response.body
      expect(resource.reload.title).to eq("Published course contribution reference")
    end
  end

  describe "#update_course" do
    it "renames and moves a course while preserving its id and resource references" do
      resource = publish_resource
      put "/isbf/learning/courses/#{course["id"]}.json", params: { name: "中级微观经济学", grade: 2 }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("course")).to include(
        "id" => course["id"],
        "name" => "中级微观经济学",
        "grade" => 2,
      )
      get "/isbf/learning/resources.json", params: { course_id: course["id"] }
      expect(response.parsed_body.fetch("resources").first).to include(
        "id" => resource.id,
        "grade" => 2,
      )
    end

    it "denies ordinary users and duplicate course names" do
      IsbfLearning::Courses.create(admin, name: "管理学", grade: 2)
      sign_in(member)
      put "/isbf/learning/courses/#{course["id"]}.json", params: { name: "未授权编辑", grade: 2 }
      expect(response.status).to eq(403)
      sign_in(admin)
      put "/isbf/learning/courses/#{course["id"]}.json", params: { name: "管理学", grade: 2 }
      expect(response.status).to eq(422)
      expect(IsbfLearning::Courses.find(course["id"])["grade"]).to eq(1)
    end
  end

  describe "#update_grade" do
    it "updates the parent label without changing course or resource ids" do
      resource = publish_resource
      put "/isbf/learning/grades/1.json", params: { name: "基础课程" }
      expect(response.status).to eq(200), response.body
      get "/isbf/learning/courses.json"
      expect(response.parsed_body.fetch("grades").first).to include("id" => 1, "label" => "基础课程")
      expect(IsbfLearning::Courses.find(course["id"])["grade"]).to eq(1)
      expect(resource.reload.custom_fields[IsbfLearning::COURSE_FIELD]).to eq(course["id"])
    end

    it "denies ordinary users" do
      sign_in(member)
      put "/isbf/learning/grades/1.json", params: { name: "未授权分类" }
      expect(response.status).to eq(403)
    end
  end

  describe "#contributor_users" do
    it "denies student number searches by ordinary users" do
      sign_in(member)
      get "/isbf/learning/contributor-users.json", params: { student_number: "20260001" }
      expect(response.status).to eq(403)
    end
  end
end
