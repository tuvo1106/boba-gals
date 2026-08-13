require "rails_helper"

# §15: scraped by kube-prometheus-stack, not the kubelet. Unauthenticated
# deliberately — the ingress never routes here (§14.2), so this is only ever
# reachable in-cluster.
RSpec.describe "GET /metrics (§15)", type: :request do
  let(:store) { create(:store, :with_stations) }
  let(:menu_item) { create(:menu_item, store: store) }

  it "serves Prometheus text format" do
    get "/metrics"

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to start_with("text/plain")
  end

  # The gauges are computed fresh from Postgres on every scrape (config
  # comment in config/initializers/yabeda.rb has the reasoning), so this
  # exercises that path rather than trusting an in-process counter.
  it "reports the current kitchen queue depth" do
    order = create(:order, store: store)
    create(:order_item, order: order, menu_item: menu_item, status: "queued")
    create(:order_item, order: order, menu_item: menu_item, status: "queued")
    create(:order_item, order: order, menu_item: menu_item, status: "finished", finished_at: Time.current)

    get "/metrics"

    expect(response.body).to include(%(boba_gals_queue_depth{store="#{store.id}"} 2.0))
  end

  it "reports the running quality-breach and remake totals from scheduler_events" do
    item = create(:order_item, order: create(:order, store: store), menu_item: menu_item)
    SchedulerEvent.record!(store: store, event_type: "quality_breach", order_item: item)
    SchedulerEvent.record!(store: store, event_type: "item_remade", order_item: item)

    get "/metrics"

    expect(response.body).to include(%(boba_gals_quality_breaches{store="#{store.id}"} 1.0))
    expect(response.body).to include(%(boba_gals_remakes{store="#{store.id}"} 1.0))
  end

  it "reports the concurrent large-order rate among currently open orders" do
    large = create(:order, store: store, status: "in_progress")
    7.times { |i| create(:order_item, order: large, menu_item: menu_item, sequence: i + 1) }
    small = create(:order, store: store, status: "in_progress")
    create(:order_item, order: small, menu_item: menu_item, sequence: 1)

    get "/metrics"

    expect(response.body).to include(%(boba_gals_concurrent_large_order_rate{store="#{store.id}"} 0.5))
  end
end
