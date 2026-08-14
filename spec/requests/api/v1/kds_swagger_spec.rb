require 'swagger_helper'

RSpec.describe 'Api::V1::Kds', type: :request do
  let!(:store) { create(:store) }
  let!(:station) { create(:station, store: store, name: 'Bar 1') }
  let!(:barista) { create(:barista, store: store, name: 'Sam', pin: '1234') }
  let(:token) { KdsToken.issue(barista: barista, station: station) }

  def queue_drink(order: create(:order, store: store), **attrs)
    create(:order_item, order: order, menu_item: create(:menu_item, store: store), **attrs)
  end

  path '/api/v1/kds/session' do
    post 'Exchanges a barista PIN and station for a station token (§13.3)' do
      tags 'Kitchen display'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { barista_pin: { type: :string }, station_id: { type: :integer } },
        required: %w[barista_pin station_id]
      }

      response '201', 'session issued' do
        schema '$ref' => '#/components/schemas/KdsSession'
        let(:body) { { barista_pin: '1234', station_id: station.id } }
        run_test!
      end

      response '401', 'wrong PIN or unknown station — identical either way, so the response cannot enumerate stations' do
        let(:body) { { barista_pin: '0000', station_id: station.id } }
        run_test!
      end
    end
  end

  path '/api/v1/kds/queue' do
    get 'The scheduler-ordered queue: in-progress work, next-up, and depth (§9.4)' do
      tags 'Kitchen display'
      produces 'application/json'
      security [ kds_token: [] ]

      response '200', 'queue snapshot' do
        schema '$ref' => '#/components/schemas/QueueUpdate'
        let(:Authorization) { "Bearer #{token}" }
        before { queue_drink }
        run_test!
      end

      response '401', 'no station token' do
        let(:Authorization) { nil }
        run_test!
      end
    end
  end

  path '/api/v1/kds/items/start' do
    post 'Claims the oldest queued drink — no id, the server decides (§6.2)' do
      tags 'Kitchen display'
      produces 'application/json'
      security [ kds_token: [] ]

      response '200', 'claimed drink' do
        schema '$ref' => '#/components/schemas/KdsItem'
        let(:Authorization) { "Bearer #{token}" }
        before { queue_drink }
        run_test!
      end

      response '404', 'nothing queued' do
        let(:Authorization) { "Bearer #{token}" }
        run_test!
      end
    end
  end

  path '/api/v1/kds/items/{id}/finish' do
    parameter name: :id, in: :path, type: :integer

    post 'Finishes a drink' do
      tags 'Kitchen display'
      produces 'application/json'
      security [ kds_token: [] ]

      response '200', 'finished drink' do
        schema '$ref' => '#/components/schemas/KdsItem'
        let(:Authorization) { "Bearer #{token}" }
        let(:id) { queue_drink(status: 'in_progress', started_at: 1.minute.ago, station: station).id }
        run_test!
      end

      response '422', 'the drink was never started' do
        let(:Authorization) { "Bearer #{token}" }
        let(:id) { queue_drink.id }
        run_test!
      end
    end
  end

  path '/api/v1/kds/items/{id}/fail' do
    parameter name: :id, in: :path, type: :integer

    post 'Fails a drink for a reason and returns the remake (§9.4)' do
      tags 'Kitchen display'
      consumes 'application/json'
      produces 'application/json'
      security [ kds_token: [] ]
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { reason: { '$ref' => '#/components/schemas/FailReason' } },
        required: %w[reason]
      }

      response '200', 'the remake, not the failed drink' do
        schema '$ref' => '#/components/schemas/KdsItem'
        let(:Authorization) { "Bearer #{token}" }
        let(:id) { queue_drink(status: 'in_progress', started_at: 1.minute.ago, station: station).id }
        let(:body) { { reason: 'spill' } }
        run_test!
      end
    end
  end

  path '/api/v1/kds/items/{id}/undo' do
    parameter name: :id, in: :path, type: :integer

    post 'Reverts the last transition within the 60s window (§9.4)' do
      tags 'Kitchen display'
      produces 'application/json'
      security [ kds_token: [] ]

      response '200', 'reverted drink' do
        schema '$ref' => '#/components/schemas/KdsItem'
        let(:Authorization) { "Bearer #{token}" }
        let(:id) do
          item = queue_drink(status: 'in_progress', started_at: 1.minute.ago, station: station)
          post "/api/v1/kds/items/#{item.id}/finish", headers: { 'Authorization' => "Bearer #{token}" }
          item.id
        end
        run_test!
      end
    end
  end
end
