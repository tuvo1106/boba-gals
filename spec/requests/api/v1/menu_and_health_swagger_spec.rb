require 'swagger_helper'

RSpec.describe 'Api::V1 menu and health', type: :request do
  let!(:store) { create(:store) }

  path '/api/v1/menu' do
    get 'Returns the available menu' do
      tags 'Ordering'
      produces 'application/json'

      response '200', 'menu' do
        schema '$ref' => '#/components/schemas/Menu'

        before { create(:menu_item, :with_options, store: store) }

        run_test!
      end
    end
  end

  path '/api/v1/health' do
    get 'Kiosk connectivity probe (§9.3)' do
      tags 'Ordering'
      produces 'application/json'

      response '200', 'store health' do
        schema '$ref' => '#/components/schemas/Health'

        run_test!
      end
    end
  end
end
