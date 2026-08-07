require "rails_helper"

# DESIGN.md §14.3: `/up` is what the kubelet polls for both liveness and
# readiness. It must stay a pure "can this pod serve" check — the business-level
# question of whether the store is taking orders belongs to /api/v1/health, and
# conflating them would let an owner flipping `accepting_orders` off trigger pod
# restarts.
RSpec.describe "GET /up", type: :request do
  it "returns 200 when the app can boot its connections" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
