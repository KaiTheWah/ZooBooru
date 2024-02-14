module Users
  class EmailConfirmationMailer < ApplicationMailer
    helper ApplicationHelper
    helper UsersHelper
    default from: PawsMovin.config.mail_from_addr, content_type: "text/html"

    def confirmation(user)
      @user = user
      mail(to: @user.email, subject: "#{PawsMovin.config.app_name} account confirmation")
    end
  end
end
