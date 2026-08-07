module Api
  module V1
    class BaseController < ApplicationController
      rescue_from ActiveRecord::RecordNotFound, with: :not_found

      private

      # v1 serves a single store. The schema is store-scoped throughout, so
      # multi-store reduces mostly to request routing and admin scoping (§16) —
      # this method is the seam where that routing will land.
      # @return [Store]
      def current_store
        @current_store ||= Store.first!
      end

      def not_found
        render json: { error: "not found" }, status: :not_found
      end

      def unprocessable(messages)
        render json: { errors: Array(messages) }, status: :unprocessable_content
      end
    end
  end
end
