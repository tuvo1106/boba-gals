require 'swagger_helper'

RSpec.describe 'POST /api/v1/admin/breaking_points (§10.5 #4)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session', params: { email: admin.email, password: 'correct-horse-battery-staple' }, as: :json
  end

  path '/api/v1/admin/breaking_points' do
    post 'Raises demand until overall p90 crosses target — the shop\'s real capacity (§10.5 #4)' do
      tags 'Admin — simulation'
      consumes 'application/json'
      produces 'application/json'
      security [ admin_session: [] ]
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          seed: { type: :integer },
          seeds: { type: :integer },
          stations: { type: :integer },
          target_seconds: { type: :number }
        }
      }

      # Narrowed to two points, same reason and mechanism as
      # spec/requests/api/v1/breaking_points_spec.rb.
      response '200', 'the swept points, ascending, and the capacity they found' do
        schema '$ref' => '#/components/schemas/BreakingPoint'
        let(:body) { { seed: 7 } }
        before do
          sign_in
          stub_const('Simulator::BreakingPoint::POINTS', [ 0.5, 1.0 ])
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
