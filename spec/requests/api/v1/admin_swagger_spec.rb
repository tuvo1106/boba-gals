require 'swagger_helper'

RSpec.describe 'Admin API (§13.4)', type: :request do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, email: 'owner@bobagals.test', password: 'correct-horse-battery-staple') }

  def sign_in
    post '/api/v1/admin/session',
         params: { email: admin.email, password: 'correct-horse-battery-staple' },
         as: :json
  end

  path '/api/v1/admin/session' do
    post 'Signs in (§13.4) — identical response for a wrong password or an unknown email' do
      tags 'Admin'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { email: { type: :string }, password: { type: :string } },
        required: %w[email password]
      }

      response '200', 'signed in' do
        schema '$ref' => '#/components/schemas/AdminUser'
        let(:body) { { email: admin.email, password: 'correct-horse-battery-staple' } }
        run_test!
      end

      response '401', 'wrong email or password' do
        let(:body) { { email: admin.email, password: 'wrong' } }
        run_test!
      end
    end

    get 'Who is signed in — the dashboard\'s first paint' do
      tags 'Admin'
      produces 'application/json'
      security [ admin_session: [] ]

      response '200', 'the signed-in admin' do
        schema '$ref' => '#/components/schemas/AdminUser'
        before { sign_in }
        run_test!
      end

      response '401', 'no session' do
        run_test!
      end
    end

    delete 'Signs out' do
      tags 'Admin'
      security [ admin_session: [] ]

      response '204', 'signed out' do
        before { sign_in }
        run_test!
      end
    end
  end

  path '/api/v1/admin/scheduler_config' do
    get 'The store\'s effective scheduler config (§6.6, §10.6) — every key present, defaults included' do
      tags 'Admin'
      produces 'application/json'
      security [ admin_session: [] ]

      response '200', 'effective config' do
        schema '$ref' => '#/components/schemas/SchedulerConfigResponse'
        before { sign_in }
        run_test!
      end
    end

    patch 'Applies a scheduler config change and returns what is now live (§10.6)' do
      tags 'Admin'
      consumes 'application/json'
      produces 'application/json'
      security [ admin_session: [] ]
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          scheduler_config: {
            type: :object,
            description: 'A subset of UpdateSchedulerConfig::SCHEMA keys — merged, not replaced'
          }
        },
        required: %w[scheduler_config]
      }

      response '200', 'now live' do
        schema '$ref' => '#/components/schemas/SchedulerConfigResponse'
        let(:body) { { scheduler_config: { quantum: 240 } } }
        before { sign_in }
        run_test!
      end

      response '422', 'an invalid or unknown key' do
        let(:body) { { scheduler_config: { quantum: 'not-a-number' } } }
        before { sign_in }
        run_test!
      end
    end
  end

  path '/api/v1/admin/prep_time_stats' do
    get 'The learned prep time (§7.3) beside the seeded guess, per menu item' do
      tags 'Admin'
      produces 'application/json'
      security [ admin_session: [] ]

      response '200', 'prep time stats' do
        schema '$ref' => '#/components/schemas/PrepTimeStats'
        before { sign_in }
        run_test!
      end
    end
  end
end
