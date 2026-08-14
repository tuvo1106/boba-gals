require 'swagger_helper'

RSpec.describe 'GET /api/v1/board', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store, base_prep_seconds: 60) }

  path '/api/v1/board' do
    get 'The customer board: making + ready, first names and codes only (§9.5, §13.1)' do
      tags 'Board'
      produces 'application/json'

      response '200', 'board snapshot' do
        schema '$ref' => '#/components/schemas/BoardUpdate'

        before do
          order = create(:order, store: store, customer_first_name: 'Sarah')
          create(:order_item, order: order, menu_item: menu_item, label: 'Thai Tea, 50%')
        end

        run_test!
      end
    end
  end
end
