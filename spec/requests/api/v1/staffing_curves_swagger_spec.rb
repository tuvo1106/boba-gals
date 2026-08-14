require 'swagger_helper'

RSpec.describe 'POST /api/v1/admin/staffing_curves (§10.5 #3)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session', params: { email: admin.email, password: 'correct-horse-battery-staple' }, as: :json
  end

  path '/api/v1/admin/staffing_curves' do
    post 'For each open hour, the fewest stations that hold p90 under target (§10.5 #3)' do
      tags 'Admin — simulation'
      consumes 'application/json'
      produces 'application/json'
      security [ admin_session: [] ]
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          seed: { type: :integer },
          seeds: { type: :integer },
          demand_multiplier: { type: :number },
          target_seconds: { type: :number }
        }
      }

      # Narrowed the same way spec/requests/api/v1/staffing_curves_spec.rb is:
      # a low station count is itself expensive at realistic demand (1 station
      # at 1.6x costs 3.16s against 0.14s at 3), so demand drops to 0.5x too.
      response '200', 'one entry per open hour, ascending' do
        schema '$ref' => '#/components/schemas/StaffingCurve'
        let(:body) { { seed: 7, demand_multiplier: 0.5 } }
        before do
          sign_in
          stub_const('Simulator::StaffingCurve::STATIONS_TRIED', (1..3))
        end
        run_test!
      end

      response '401', 'no admin session' do
        let(:body) { { seed: 1 } }
        run_test!
      end
    end
  end
end
