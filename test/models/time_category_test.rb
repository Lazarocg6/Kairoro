require "test_helper"

class TimeCategoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "requires unique name per family" do
    @family.time_categories.create!(name: "Unique", color: "#000000", lucide_icon: "clock")

    duplicate = @family.time_categories.build(name: "Unique", color: "#111111", lucide_icon: "clock")
    assert_not duplicate.valid?
  end

  test "rejects color that is not a hex value" do
    cat = @family.time_categories.build(name: "X", color: "blue", lucide_icon: "clock")
    assert_not cat.valid?
  end

  test "subcategory inherits color from parent" do
    parent = time_categories(:work)
    sub = @family.time_categories.create!(
      name: "Research",
      color: "#111111",
      lucide_icon: "book",
      parent: parent
    )
    assert_equal parent.color, sub.color
  end

  test "category_level_limit prevents 3rd level" do
    parent = time_categories(:work)
    sub = time_categories(:deep_work)
    grand = @family.time_categories.build(
      name: "Sub-sub",
      color: "#123456",
      lucide_icon: "book",
      parent: sub
    )
    assert_not grand.valid?
    assert grand.errors[:parent].any?
  end

  test "replace_and_destroy reassigns time blocks" do
    replacement = time_categories(:leisure)
    block = TimeBlock.create!(
      family: @family,
      user: users(:family_admin),
      time_category: time_categories(:deep_work),
      started_at: 2.hours.ago,
      ended_at: 1.hour.ago
    )

    time_categories(:deep_work).replace_and_destroy!(replacement)

    block.reload
    assert_equal replacement.id, block.time_category_id
  end
end
