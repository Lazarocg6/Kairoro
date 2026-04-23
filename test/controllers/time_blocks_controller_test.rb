require "test_helper"

class TimeBlocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    ensure_tailwind_build if respond_to?(:ensure_tailwind_build)
  end

  test "index renders register page" do
    get time_blocks_url
    assert_response :success
  end

  test "create adds a time block" do
    assert_difference "TimeBlock.count", +1 do
      post time_blocks_url, params: {
        time_block: {
          time_category_id: time_categories(:deep_work).id,
          started_at: 2.hours.ago.change(sec: 0).iso8601,
          ended_at:   1.hour.ago.change(sec: 0).iso8601,
          notes: "Test"
        }
      }
    end
    assert_redirected_to time_blocks_url
  end

  test "destroy removes block" do
    block = time_blocks(:work_today)
    assert_difference "TimeBlock.count", -1 do
      delete time_block_url(block)
    end
  end
end
