module Api
  module V1
    class OrdersController < BaseController
      # POST /api/v1/orders — public, rate-limited at 10/min per IP (§13.2).
      def create
        result = CreateOrder.new(store: current_store).call(
          source: order_params[:source],
          items: item_params,
          customer_first_name: order_params[:customer_first_name],
          customer_phone: order_params[:customer_phone],
          promised_at: order_params[:promised_at]
        )

        return unprocessable(result.errors) unless result.success?

        render json: OrderSerializer.call(result.order), status: :created
      end

      # GET /api/v1/orders/:pickup_code — public.
      #
      # The pickup code *is* the token (§13.1): per-store per-day unique,
      # low-value, and throttled at 60/min per IP. Scoped to today so yesterday's
      # code cannot read today's order.
      def show
        order = current_store.orders.for_pickup_code(params[:pickup_code]).first!

        render json: OrderSerializer.call(order)
      end

      private

      def order_params
        params.expect(order: [ :source, :customer_first_name, :customer_phone, :promised_at ])
      end

      def item_params
        params.expect(order: [ items: [ [ :menu_item_id, { option_ids: [] } ] ] ])[:items].to_a.map do |item|
          { menu_item_id: item[:menu_item_id], option_ids: Array(item[:option_ids]) }
        end
      end
    end
  end
end
