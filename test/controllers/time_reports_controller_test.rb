require "test_helper"

class TimeReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build if respond_to?(:ensure_tailwind_build)
  end

  test "index renders with default period" do
    get time_reports_url
    assert_response :success
  end

  test "index supports custom range" do
    get time_reports_url, params: {
      period_type: "custom",
      start_date: 30.days.ago.to_date.iso8601,
      end_date: Date.current.iso8601
    }
    assert_response :success
  end
end
