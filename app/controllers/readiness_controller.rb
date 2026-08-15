# Readiness for the kubelet (§14.3, ADR-0008).
#
# Three health endpoints, three different questions, and conflating any two of
# them causes an outage:
#
#   /up              — is the process alive? (Rails' built-in; liveness)
#   /readyz          — can this pod serve a request? (here; readiness)
#   /api/v1/health   — is the store taking orders? (§9.1; the kiosk polls it)
#
# §14.3 is emphatic about the third: an owner switching `accepting_orders` off
# must never cause Kubernetes to restart pods. It also assumed the first could
# do the second's job, which Rails' own documentation contradicts — `/up`
# "does not reflect the status of all of your application's dependencies, such
# as the database or Redis cluster". A pod with no database reachable answers
# it 200 and is sent traffic it can only fail.
class ReadinessController < ActionController::API
  # Kept short deliberately. A readiness probe that blocks is worse than one
  # that fails: the kubelet's own timeout would fire while connections pile up
  # behind a database that is already struggling.
  TIMEOUT_SECONDS = 2

  # GET /readyz
  def show
    checks = { database: database_ready?, redis: redis_ready? }

    if checks.values.all?
      render json: { status: "ready", checks: checks }
    else
      render json: { status: "not_ready", checks: checks }, status: :service_unavailable
    end
  end

  private

  # `SELECT 1` rather than `connected?`, which reports on the connection object
  # rather than on the server — it stays true across a Postgres restart until
  # something actually tries to use it.
  #
  # Bounded by `statement_timeout`, which is what makes `TIMEOUT_SECONDS` real
  # rather than aspirational. It was declared and referenced nowhere, so a
  # wedged Postgres — accepting TCP, answering nothing — left each probe
  # occupying a Puma thread for as long as the driver would wait. `web` runs
  # `RAILS_MAX_THREADS` (5) threads and the kubelet re-probes every 5s
  # (k8s/base/web.yaml), so abandoned probes stack up on a pod that is already
  # struggling: exactly the pile-up the constant's comment says it prevents.
  #
  # Saved and restored explicitly rather than with `SET LOCAL` in a transaction.
  # That was the first attempt and it **leaked**: Rails does not materialise a
  # BEGIN for a read-only block, so on the healthy path — commit, no exception —
  # the setting survived and the connection went back to the pool carrying a
  # two-second cap on every real query. Measured: `0` before, `2s` inside, `2s`
  # still after commit. It reverted only when a statement was cancelled, which
  # is the one path that does roll back, so the failure mode was invisible
  # exactly when the probe was working.
  #
  # `ensure` rather than a transaction, so the restore does not depend on
  # transaction semantics at all. If the connection is dead by then the restore
  # fails too, but a dead connection is discarded rather than pooled.
  def database_ready?
    connection = ActiveRecord::Base.connection
    previous = connection.select_value("SHOW statement_timeout")

    begin
      connection.execute("SET statement_timeout = #{TIMEOUT_SECONDS * 1000}")
      connection.select_value("SELECT 1").present?
    ensure
      connection.execute("SET statement_timeout = #{connection.quote(previous)}")
    end
  rescue StandardError
    false
  end

  # Redis is load-bearing, not a cache (§14.4): without it ActionCable cannot
  # broadcast across pods, the board throttle cannot take its lock, and from
  # step 5 the scheduler cannot read its deficits. A pod that cannot reach it
  # should not be in the Service.
  def redis_ready?
    BobaGals::REDIS.with { |redis| redis.ping == "PONG" }
  rescue StandardError
    false
  end
end
