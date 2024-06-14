# frozen_string_literal: true

require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
    CurrentUser.user = @user
  end

  should "increment user's unread_notification_count" do
    assert_equal(false, @user.reload.has_unread_notifications?)
    assert_difference("@user.reload.unread_notification_count", 1) do
      create(:notification, user: @user)
    end
    assert_equal(true, @user.reload.has_unread_notifications?)
  end

  should "decrement user's unread_notification_count" do
    notification = create(:notification, user: @user)
    assert_equal(true, @user.reload.has_unread_notifications?)
    assert_difference("@user.reload.unread_notification_count", -1) do
      notification.update!(is_read: true)
    end
    assert_equal(false, @user.reload.has_unread_notifications?)
  end
end
