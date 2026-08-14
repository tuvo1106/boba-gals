require 'swagger_helper'

RSpec.describe 'POST /api/v1/admin/ablations (§10.5, §10.6)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session', params: { email: admin.email, password: 'correct-horse-battery-staple' }, as: :json
  end

  path '/api/v1/admin/ablations' do
    post 'The same day scheduled four ways — FIFO, RR, DRR (+ aging, + cohesion), SJF (§6.3, §10.5)' do
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
          demand_multiplier: { type: :number },
          quantum: { type: :integer }
        }
      }

      response '200', 'six arms, in §6.3 order' do
        schema '$ref' => '#/components/schemas/Ablation'
        let(:body) { { seed: 7, demand_multiplier: 1.6 } }
        before { sign_in }
        run_test!
      end

      response '401', 'no admin session — four runs per seed' do
        let(:body) { { seed: 1 } }
        run_test!
      end
    end
  end
end
