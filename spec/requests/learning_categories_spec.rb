# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF learning categories", type: :request do
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
    SiteSetting.isbf_learning_enabled = true
    SiteSetting.isbf_learning_category_id = category.id
    category.set_permissions(trust_level_0: :full, staff: :full)
    category.save!
  end

  it "adds a category and keeps existing course associations when assigning a new course" do
    existing = IsbfLearning::Courses.create(admin, name: "已有课程", grade: 1)
    sign_in(admin)
    post "/isbf/learning/grades.json", params: { name: "  通识课程  " }
    expect(response.status).to eq(201), response.body
    grade = response.parsed_body.fetch("grade")
    expect(grade).to include("id" => 5, "label" => "通识课程")

    post "/isbf/learning/courses.json",
         params: {
           name: "新分类课程",
           grade: grade.fetch("id")
         }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.dig("course", "grade")).to eq(5)
    get "/isbf/learning/courses.json"
    expect(response.parsed_body.fetch("grades")).to include(grade)
    expect(response.parsed_body.fetch("courses")).to include(existing.as_json)
  end

  it "allows only administrators to add a category" do
    [nil, member, moderator].each do |actor|
      sign_in(actor) if actor
      post "/isbf/learning/grades.json", params: { name: "Unauthorized" }
      expect(response.status).to eq(403), response.body
    end
    expect(IsbfLearning::Courses.grades.map { |grade| grade[:id] }).to eq(
      [1, 2, 3, 4]
    )
  end

  it "validates category names and rejects normalized duplicates" do
    sign_in(admin)
    ["", "x" * 81, "line\nbreak", { bad: "name" }, "大一"].each do |name|
      post "/isbf/learning/grades.json", params: { name: name }
      expect(response.status).to eq(422), response.body
    end
    post "/isbf/learning/grades.json", params: { name: " ＡＢＣ " }
    expect(response.status).to eq(201), response.body
    post "/isbf/learning/grades.json", params: { name: "abc" }
    expect(response.status).to eq(422), response.body
  end

  it "edits a custom category and never reuses archived category identifiers" do
    first = IsbfLearning::Courses.create_grade(admin, name: "第一分类")
    sign_in(admin)
    put "/isbf/learning/grades/#{first.fetch("id")}.json",
        params: {
          name: "已编辑分类"
        }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.dig("grade", "label")).to eq("已编辑分类")
    PluginStore.set(
      IsbfLearning::STORE,
      "deleted_grades",
      first.fetch("id").to_s => {
        "deleted_at" => Time.now.utc.iso8601
      }
    )
    post "/isbf/learning/grades.json", params: { name: "第二分类" }
    expect(response.parsed_body.dig("grade", "id")).to eq(6)
    post "/isbf/learning/courses.json",
         params: {
           name: "已归档分类课程",
           grade: first.fetch("id")
         }
    expect(response.status).to eq(422), response.body
  end
end
