require 'swagger_helper'

RSpec.describe 'Api::V1::Orders', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let!(:menu_item) { create(:menu_item, :thai_tea, store: store) }

  path '/api/v1/orders' do
    post 'Places an order (§9.1) — payment is authorized in the same transaction (§9.3)' do
      tags 'Ordering'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          order: {
            type: :object,
            properties: {
              source: { type: :string, enum: %w[kiosk web] },
              customer_first_name: { type: :string },
              customer_phone: { type: :string },
              items: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    menu_item_id: { type: :integer },
                    option_ids: { type: :array, items: { type: :integer } }
                  },
                  required: %w[menu_item_id]
                }
              }
            },
            required: %w[source items]
          }
        },
        required: %w[order]
      }

      response '201', 'order placed' do
        schema '$ref' => '#/components/schemas/PlacedOrder'
        let(:body) { { order: { source: 'kiosk', customer_first_name: 'Sam', items: [ { menu_item_id: menu_item.id } ] } } }
        run_test!
      end

      response '422', 'no items' do
        let(:body) { { order: { source: 'kiosk', customer_first_name: 'Sam', items: [] } } }
        run_test!
      end
    end
  end

  path '/api/v1/orders/{pickup_code}' do
    parameter name: :pickup_code, in: :path, type: :string,
              description: 'The 4-character unambiguous pickup code (§13.1) — the capability token, not an id'

    get 'Order status and ETA (§9.1) — public, the code is the token' do
      tags 'Ordering'
      produces 'application/json'

      response '200', 'order status' do
        schema '$ref' => '#/components/schemas/PlacedOrder'
        let(:pickup_code) do
          order = create(:order, store: store, pickup_code: 'K7QF', quoted_wait_seconds: 240)
          create(:order_item, order: order, menu_item: menu_item)
          order.pickup_code
        end
        run_test!
      end

      response '404', 'unknown code' do
        let(:pickup_code) { 'ZZZZ' }
        run_test!
      end
    end
  end
end
