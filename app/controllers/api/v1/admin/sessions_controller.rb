module Api
  module V1
    module Admin
      # Sign in and out of the dashboard (§13.4).
      #
      # No signup, no password reset, no roles. The one admin user is created by
      # seed or console — there is nothing here for an attacker to enumerate
      # because there is nothing here that creates users.
      class SessionsController < BaseController
        skip_before_action :authenticate_admin!, only: [ :create ]

        # POST /api/v1/admin/session
        def create
          admin = AdminUser.find_by(email: params[:email].to_s.strip.downcase)

          # `&.` rather than a nil guard with its own message: a wrong email and
          # a wrong password must be indistinguishable, or the endpoint answers
          # "does this address have an account".
          unless admin&.authenticate(params[:password].to_s)
            return render json: { error: "invalid email or password" }, status: :unauthorized
          end

          # Rotates the session id on privilege change, so a session fixated
          # before login is not the one that ends up authenticated.
          reset_session
          session[:admin_user_id] = admin.id

          render json: serialize(admin)
        end

        # GET /api/v1/admin/session — who am I, for the dashboard's first paint.
        def show
          render json: serialize(current_admin)
        end

        # DELETE /api/v1/admin/session
        def destroy
          reset_session

          head :no_content
        end

        private

        def serialize(admin)
          { email: admin.email }
        end
      end
    end
  end
end
