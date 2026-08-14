require 'swagger_helper'

RSpec.describe 'POST /api/v1/admin/quantum_sweeps (§10.5)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session', params: { email: admin.email, password: 'correct-horse-battery-staple' }, as: :json
  end

  path '/api/v1/admin/quantum_sweeps' do
    post 'The same day run at ten quantum values, so the crossover can be read off the chart (§10.5 #2)' do
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
          demand_multiplier: { type: :number }
        }
      }

      # Narrowed to two points, same reason and mechanism as
      # spec/requests/api/v1/quantum_sweeps_spec.rb — this spec is about
      # routing, auth, and response shape; QuantumSweep's own spec covers the
      # real ten-point range as :slow (docs/testing.md).
      response '200', 'the swept points, ascending' do
        schema '$ref' => '#/components/schemas/QuantumSweep'
        let(:body) { { seed: 7, demand_multiplier: 1.6 } }
        before do
          sign_in
          stub_const('Simulator::QuantumSweep::POINTS', [ 30, 400 ])
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
