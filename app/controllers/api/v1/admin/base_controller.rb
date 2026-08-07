module Api
  module V1
    module Admin
      # Every /admin/* endpoint requires the single admin session (§13.4).
      #
      # This exists from the first deploy, not after it: PATCH
      # /admin/scheduler_config changes live scheduler behaviour, and an open
      # admin API is not something to leave lying around "briefly".
      class BaseController < Api::V1::BaseController
        include ActionController::Cookies

        before_action :authenticate_admin!

        private

        def authenticate_admin!
          return if current_admin

          render json: { error: "authentication required" }, status: :unauthorized
        end

        def current_admin
          return @current_admin if defined?(@current_admin)

          @current_admin = AdminUser.find_by(id: session[:admin_user_id])
        end
      end
    end
  end
end
