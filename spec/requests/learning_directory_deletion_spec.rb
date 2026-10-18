# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfLearning::LibraryController, type: :request do
  fab!(:category)
  fab!(:admin)
  fab!(:member) do
    Fabricate(:user, active: true, approved: true, refresh_auto_groups: true)
  end
  fab!(:moderator) do
    Fabricate(
      :moderator,
      active: true,
      approved: true,
      refresh_auto_groups: true
    )
  end

  before do
    PluginStore.set(IsbfLearning::STORE, "courses", [])
    PluginStore.set(IsbfLearning::STORE, "deleted_grades", {})
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
    sign_in(admin)
  end

  def course(grade = 1)
    IsbfLearning::Courses.create(
      admin,
      name: "Course #{SecureRandom.hex(4)}",
      grade: grade
    )
  end

  def publish(entry)
    post "/isbf/learning/resources.json",
         params: {
           course_id: entry["id"],
           title: "Course deletion resource #{SecureRandom.hex(4)}",
           link: "https://example.org/resource"
         }
    expect(response.status).to eq(200), response.body
    Topic.find(response.parsed_body.fetch("resource").fetch("id"))
  end

  def plan(entry, kind = "courses")
    get "/isbf/learning/#{kind}/#{entry}/deletion-plan.json"
    expect(response.status).to eq(200), response.body
    response.parsed_body
  end

  def destroy(entry, data, kind = "courses", **overrides)
    delete "/isbf/learning/#{kind}/#{entry}.json",
           params: {
             confirmation_token: data["confirmation_token"],
             confirmation_count: data["required_confirmations"],
             cascade: data["has_children"]
           }.merge(overrides)
  end

  it "requires a signed plan and two confirmations to delete an empty course" do
    entry = course
    delete "/isbf/learning/courses/#{entry["id"]}.json"
    expect(response.status).to eq(409)
    data = plan(entry["id"])
    expect(data).to include(
      "required_confirmations" => 2,
      "resource_count" => 0
    )
    destroy(entry["id"], data, confirmation_count: 1)
    expect(response.status).to eq(409)
    expect(IsbfLearning::Courses.find(entry["id"])).to be_present
    destroy(entry["id"], data)
    expect(response.status).to eq(200), response.body
    expect(IsbfLearning::Courses.find(entry["id"])).to be_nil
    expect(
      IsbfLearning::Courses
        .list(include_deleted: true)
        .find { |value| value["id"] == entry["id"] }
    ).to include("deleted_by_id" => admin.id)
  end

  it "requires the third confirmation and cascade consent, then deletes all course resources including hidden resources" do
    entry = course
    first = publish(entry)
    hidden = publish(entry)
    hidden.update!(visible: false)
    untouched = publish(course)
    data = plan(entry["id"])
    expect(data).to include(
      "required_confirmations" => 3,
      "resource_count" => 2
    )
    destroy(entry["id"], data, confirmation_count: 2)
    expect(response.status).to eq(409)
    destroy(entry["id"], data, cascade: false)
    expect(response.status).to eq(409)
    expect(first.reload.deleted_at).to be_nil
    destroy(entry["id"], data)
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("deleted_resources")).to eq(2)
    expect(Topic.with_deleted.find(first.id).deleted_at).to be_present
    expect(Topic.with_deleted.find(hidden.id).deleted_at).to be_present
    expect(untouched.reload.deleted_at).to be_nil
    get "/isbf/learning/contributions.json"
    expect(
      response.parsed_body.fetch("resources").map { |resource| resource["id"] }
    ).to eq([untouched.id])
  end

  it "archives a category, all its courses and resources while preserving other categories" do
    first = course
    second = course
    topics = [publish(first), publish(second)]
    retained = course(2)
    resource = publish(retained)
    data = plan(1, "grades")
    expect(data).to include(
      "required_confirmations" => 3,
      "course_count" => 2,
      "resource_count" => 2
    )
    destroy(1, data, "grades")
    expect(response.status).to eq(200), response.body
    expect(
      IsbfLearning::Courses.grades.map { |entry| entry[:id] }
    ).not_to include(1)
    expect(IsbfLearning::Courses.list.map { |entry| entry["id"] }).to eq(
      [retained["id"]]
    )
    expect(
      Topic
        .with_deleted
        .where(id: topics.map(&:id))
        .where.not(deleted_at: nil)
        .count
    ).to eq(2)
    expect(resource.reload.deleted_at).to be_nil
    post "/isbf/learning/courses.json",
         params: {
           name: "Rejected orphan",
           grade: 1
         }
    expect(response.status).to eq(422)
  end

  it "uses three confirmations for a category with empty courses and two for an empty category" do
    course
    expect(plan(1, "grades")["required_confirmations"]).to eq(3)
    data = plan(4, "grades")
    expect(data["required_confirmations"]).to eq(2)
    destroy(4, data, "grades")
    expect(response.status).to eq(200)
    expect(
      IsbfLearning::Courses.grades.map { |entry| entry[:id] }
    ).not_to include(4)
  end

  it "rejects stale plans after new resources or renamed courses without deleting anything" do
    entry = course
    data = plan(entry["id"])
    resource = publish(entry)
    destroy(entry["id"], data)
    expect(response.status).to eq(409)
    data = plan(entry["id"])
    IsbfLearning::Courses.update(
      admin,
      entry["id"],
      name: "Renamed course",
      grade: 1
    )
    destroy(entry["id"], data)
    expect(response.status).to eq(409)
    expect(resource.reload.deleted_at).to be_nil
  end

  it "rejects stale category plans after another course is added" do
    data = plan(1, "grades")
    course
    destroy(1, data, "grades")
    expect(response.status).to eq(409)
    expect(IsbfLearning::Courses.grades.length).to eq(4)
  end

  it "binds confirmations to the selected directory, user and expiry" do
    entry = course
    data = plan(entry["id"])
    another = course
    destroy(another["id"], data)
    expect(response.status).to eq(409)
    sign_in(Fabricate(:admin))
    destroy(entry["id"], data)
    expect(response.status).to eq(409)
    sign_in(admin)
    freeze_time(11.minutes.from_now) do
      destroy(entry["id"], data)
      expect(response.status).to eq(409)
    end
  end

  it "does not grant deletion to ordinary members" do
    entry = course
    data = plan(entry["id"])
    sign_in(member)
    get "/isbf/learning/courses/#{entry["id"]}/deletion-plan.json"
    expect(response.status).to eq(403)
    destroy(entry["id"], data)
    expect(response.status).to eq(403)
    expect(IsbfLearning::Courses.find(entry["id"])).to be_present
  end

  it "uses the existing moderator management permission and rechecks revocation" do
    unless defined?(DiscourseAcademyRoles::ModeratorPermissions)
      skip "Academy integration is not installed"
    end
    SiteSetting.academy_official_group = Fabricate(:group).id
    SiteSetting.academy_official_category = Fabricate(:category).id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.academy_moderators_manage_resources = true
    SiteSetting.academy_moderators_review_resources = false
    entry = course
    sign_in(moderator)
    data = plan(entry["id"])
    SiteSetting.academy_moderators_manage_resources = false
    SiteSetting.academy_moderators_review_resources = true
    destroy(entry["id"], data)
    expect(response.status).to eq(403)
    SiteSetting.academy_moderators_manage_resources = true
    destroy(entry["id"], plan(entry["id"]))
    expect(response.status).to eq(200), response.body
  end

  it "rolls back resources and catalog together when catalog storage fails" do
    entry = course
    resource = publish(entry)
    data = plan(entry["id"])
    PluginStore
      .stubs(:set)
      .with(IsbfLearning::STORE, "courses", anything)
      .returns(false)
    destroy(entry["id"], data)
    expect(response.status).to eq(422)
    expect(IsbfLearning::Courses.find(entry["id"])).to be_present
    expect(Topic.with_deleted.find(resource.id).deleted_at).to be_nil
  end

  it "prevents queued resources from being approved into a deleted course" do
    entry = course
    sign_in(member)
    post "/isbf/learning/resources.json",
         params: {
           course_id: entry["id"],
           title: "Pending orphan resource",
           link: "https://example.org/pending"
         }
    expect(response.status).to eq(200)
    queued = ReviewableQueuedPost.order(:id).last
    sign_in(admin)
    destroy(entry["id"], plan(entry["id"]))
    expect(response.status).to eq(200)
    expect { queued.perform(admin, :approve_post) }.to raise_error(
      Discourse::InvalidParameters
    )
    expect(queued.reload).to be_pending
  end
end
