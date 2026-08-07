require "rails_helper"

# The distinction ADR-0008 exists to protect. Rails' own /up returns 200 whenever
# the app booted, so a pod with no database reachable was Ready and receiving
# traffic — observed on the first kind deploy, with postgres-0 still Pending.
RSpec.describe "kubelet probes (§14.3)" do
  describe "GET /readyz" do
    it "is ready when Postgres and Redis both answer" do
      get "/readyz"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(
        "status" => "ready", "checks" => { "database" => true, "redis" => true }
      )
    end

    it "is not ready when the database is unreachable" do
      allow(ActiveRecord::Base.connection).to receive(:select_value)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body)["checks"]).to include("database" => false)
    end

    # Redis is load-bearing, not a cache (§14.4): without it broadcasts never
    # cross pods and the board throttle cannot take its lock. A pod that cannot
    # reach it should leave the Service.
    it "is not ready when Redis is unreachable" do
      allow(BobaGals::REDIS).to receive(:with).and_raise(Redis::CannotConnectError)

      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body)["checks"]).to include("redis" => false)
    end

    it "names which dependency failed, so a 503 does not require reading logs" do
      allow(BobaGals::REDIS).to receive(:with).and_raise(Redis::CannotConnectError)

      get "/readyz"

      expect(JSON.parse(response.body)["checks"]).to eq("database" => true, "redis" => false)
    end
  end

  describe "GET /up" do
    it "answers without touching the database" do
      # Liveness must not restart every pod over a database blip (ADR-0008), so
      # it has to keep answering when the database does not.
      allow(ActiveRecord::Base.connection).to receive(:select_value)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      get "/up"

      expect(response).to have_http_status(:ok)
    end
  end
end
