require 'swagger_helper'

RSpec.describe 'POST /api/v1/admin/simulations (§9.1, §10.1)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session', params: { email: admin.email, password: 'correct-horse-battery-staple' }, as: :json
  end

  path '/api/v1/admin/simulations' do
    post 'Runs a scenario server-side and returns metrics plus the lane-ribbon timeline (§10.1, §10.6)' do
      tags 'Admin — simulation'
      consumes 'application/json'
      produces 'application/json'
      security [ admin_session: [] ]
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          seed: { type: :integer },
          stations: { type: :integer },
          demand_multiplier: { type: :number },
          large_order_rate: { type: :number },
          window_from: { type: :number },
          window_seconds: { type: :number },
          scheduler_config: { type: :object, description: 'A subset of UpdateSchedulerConfig::SCHEMA keys' }
        }
      }

      response '200', 'a day\'s metrics and timeline' do
        schema '$ref' => '#/components/schemas/SimulationRun'
        let(:body) { { seed: 7 } }
        before { sign_in }
        run_test!
      end

      response '401', 'no admin session — a run is unbounded compute' do
        let(:body) { { seed: 1 } }
        run_test!
      end
    end
  end
end
