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

  # `TIMEOUT_SECONDS` was declared and referenced nowhere, so the file
  # documented a bound it did not have: a wedged Postgres (accepting TCP,
  # answering nothing) held a Puma thread per probe. This asserts the bound is
  # actually applied to the connection, which is the part that was missing.
  describe "the probe bounds itself (§14.3)" do
    it "runs its database check under a statement timeout" do
      statements = []
      allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |orig, sql, *rest|
        statements << sql
        orig.call(sql, *rest)
      end

      get "/readyz"

      expect(statements).to include(a_string_matching(/SET statement_timeout = 2000/))
    end

    # The first version of this fix used `SET LOCAL` in a transaction and
    # leaked: Rails does not materialise a BEGIN for a read-only block, so on
    # the *healthy* path the 2s cap survived onto the pooled connection and
    # would have applied to every real query after it. It reverted only when a
    # statement was cancelled — so the leak was invisible exactly when the probe
    # was working. Asserting the restore, not just the set.
    it "leaves the connection's statement_timeout exactly as it found it" do
      before = ActiveRecord::Base.connection.select_value("SHOW statement_timeout")

      get "/readyz"

      expect(response).to have_http_status(:ok)
      expect(ActiveRecord::Base.connection.select_value("SHOW statement_timeout")).to eq(before)
    end

    it "reports not_ready rather than hanging when the database check fails" do
      allow(ActiveRecord::Base.connection).to receive(:select_value).and_raise(ActiveRecord::StatementInvalid)

      get "/readyz"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["checks"]["database"]).to be(false)
    end
  end
end
