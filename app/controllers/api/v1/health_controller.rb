module Api
  module V1
    # GET /api/v1/health — the kiosk connectivity probe (§9.1).
    #
    # Deliberately business-level, not a liveness check. It answers "is the store
    # taking orders", which includes `stores.accepting_orders`. The kubelet polls
    # /up instead (§14.3) — conflating them would mean an owner flipping
    # accepting_orders off causes Kubernetes to restart pods.
    #
    # The kiosk polls this every 10s; two consecutive failures show the paused
    # state and disable ordering, with no local queue (§9.3).
    class HealthController < BaseController
      def show
        store = Store.first

        if store.nil?
          return render json: { accepting_orders: false, reason: "no store configured" },
                        status: :service_unavailable
        end

        render json: {
          accepting_orders: store.accepting_orders,
          store_name: store.name,
          server_time: Time.current
        }
      end
    end
  end
end
