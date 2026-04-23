require "test_helper"

class TimeBlockTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user   = users(:family_admin)
  end

  test "duration is computed from started_at and ended_at" do
    block = TimeBlock.new(
      family: @family,
      user: @user,
      time_category: time_categories(:deep_work),
      started_at: Time.zone.parse("2026-04-10 10:00"),
      ended_at:   Time.zone.parse("2026-04-10 11:30")
    )
    assert_equal 90, block.duration_minutes
    assert_equal "1h 30m", block.duration_label
  end

  test "ended_at must be after started_at" do
    block = TimeBlock.new(
      family: @family,
      user: @user,
      time_category: time_categories(:deep_work),
      started_at: Time.zone.now,
      ended_at:   1.hour.ago
    )
    assert_not block.valid?
    assert block.errors[:ended_at].any?
  end

  test "rejects unreasonably long durations" do
    block = TimeBlock.new(
      family: @family,
      user: @user,
      time_category: time_categories(:deep_work),
      started_at: Time.zone.parse("2026-04-10 00:00"),
      ended_at:   Time.zone.parse("2026-04-12 00:00")
    )
    assert_not block.valid?
  end

  test "aggregate_by_category rolls up sub-categories under their parent" do
    TimeBlock.delete_all

    parent = time_categories(:work)
    child  = time_categories(:deep_work)

    TimeBlock.create!(
      family: @family, user: @user, time_category: child,
      started_at: Time.zone.parse("2026-04-10 10:00"),
      ended_at:   Time.zone.parse("2026-04-10 11:00")
    )
    TimeBlock.create!(
      family: @family, user: @user, time_category: parent,
      started_at: Time.zone.parse("2026-04-10 12:00"),
      ended_at:   Time.zone.parse("2026-04-10 12:30")
    )

    totals = TimeBlock.aggregate_by_category(
      TimeBlock.where(family: @family).includes(time_category: :parent)
    )

    row = totals[parent.id]
    assert_equal 90, row[:minutes]
    assert_equal 60, row[:subcategories][child.id][:minutes]
  end
end
