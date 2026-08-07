require "rails_helper"

RSpec.describe "Admin API (§13.4)" do
  let!(:store) { create(:store, :with_stations) }
  let(:admin) { create(:admin_user, email: "owner@bobagals.test", password: "correct-horse-battery-staple") }
  let(:body) { JSON.parse(response.body) }

  def sign_in
    post "/api/v1/admin/session",
         params: { email: admin.email, password: "correct-horse-battery-staple" },
         as: :json
  end

  # This is the whole reason admin auth lands before the first deploy (§12 step
  # 4): PATCH scheduler_config changes live scheduler behaviour, and an open
  # admin API is not something to leave lying around "briefly".
  describe "authentication" do
    it "refuses every admin endpoint without a session" do
      [
        [ :get, "/api/v1/admin/scheduler_config" ],
        [ :patch, "/api/v1/admin/scheduler_config" ],
        [ :get, "/api/v1/admin/prep_time_stats" ],
        [ :get, "/api/v1/admin/session" ]
      ].each do |method, path|
        public_send(method, path)

        expect(response).to have_http_status(:unauthorized), "#{method.upcase} #{path} was not refused"
      end
    end

    it "signs in with the right password" do
      sign_in

      expect(response).to have_http_status(:ok)
      expect(body["email"]).to eq("owner@bobagals.test")
    end

    it "does not return the password digest" do
      sign_in

      expect(response.body).not_to include("digest")
    end

    # A different message for a wrong email turns this into an oracle for "does
    # this address have an account" (ADR-0006).
    it "gives the same answer for a wrong password and an unknown email" do
      post "/api/v1/admin/session", params: { email: admin.email, password: "wrong" }, as: :json
      wrong_password = [ response.status, body ]

      post "/api/v1/admin/session", params: { email: "nobody@example.com", password: "wrong" }, as: :json

      expect([ response.status, body ]).to eq(wrong_password)
    end

    it "is case- and whitespace-insensitive about the email" do
      post "/api/v1/admin/session",
           params: { email: "  #{admin.email.upcase} ", password: "correct-horse-battery-staple" },
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it "keeps the session across requests" do
      sign_in

      get "/api/v1/admin/session"

      expect(response).to have_http_status(:ok)
      expect(body["email"]).to eq("owner@bobagals.test")
    end

    it "signs out" do
      sign_in

      delete "/api/v1/admin/session"
      get "/api/v1/admin/session"

      expect(response).to have_http_status(:unauthorized)
    end

    # ADR-0006: the cookie is the CSRF defence, so its attributes are not
    # cosmetic. httponly keeps the session away from any script on the page.
    it "sets an httponly, same-site session cookie" do
      sign_in

      cookie = response.headers["Set-Cookie"].to_s

      expect(cookie).to include("_boba_gals_admin")
      expect(cookie).to match(/HttpOnly/i)
      expect(cookie).to match(/SameSite=Strict/i)
    end
  end

  describe "GET /admin/scheduler_config" do
    before { sign_in }

    # Effective, not raw: a key added to §6.6 after this store was configured
    # would otherwise read as absent and the dashboard would render a blank
    # control (§10.6).
    it "returns every §6.6 key, including ones the store has never set" do
      store.update!(scheduler_config: { "quantum" => 90 })

      get "/api/v1/admin/scheduler_config"

      expect(body["scheduler_config"]).to include(
        "quantum" => 90, "policy" => "drr", "eta_safety_factor" => 1.15
      )
    end

    it "says which keys are editable" do
      get "/api/v1/admin/scheduler_config"

      expect(body["editable"]).to match_array(UpdateSchedulerConfig::SCHEMA.keys)
    end
  end

  describe "PATCH /admin/scheduler_config" do
    before { sign_in }

    def patch_config(changes)
      patch "/api/v1/admin/scheduler_config", params: { scheduler_config: changes }, as: :json
    end

    it "applies a change and returns what is now live" do
      patch_config(quantum: 240)

      expect(response).to have_http_status(:ok)
      expect(body["scheduler_config"]["quantum"]).to eq(240)
      expect(store.reload.scheduler_config["quantum"]).to eq(240)
    end

    # A PATCH naming one key must not reset the other nine to defaults.
    it "merges rather than replaces" do
      store.update!(scheduler_config: { "quantum" => 90, "aging_rate" => 0.3 })

      patch_config(quantum: 150)

      expect(store.reload.scheduler_config).to include("quantum" => 150, "aging_rate" => 0.3)
    end

    it "changes nothing when any value is invalid" do
      patch_config(quantum: 240, aging_rate: "not-a-number")

      expect(response).to have_http_status(:unprocessable_content)
      expect(store.reload.scheduler_config["quantum"]).to be_nil
    end

    # §14.6: scheduler_config must never accumulate anything that is not
    # scheduler tuning, and must never hold a secret.
    it "rejects an unknown key rather than storing it" do
      patch_config(quantum: 240, twilio_auth_token: "sk-live-oops")

      expect(response).to have_http_status(:unprocessable_content)
      expect(body["errors"].join).to include("twilio_auth_token")
      expect(store.reload.scheduler_config).not_to have_key("twilio_auth_token")
    end

    it "refuses without a session" do
      delete "/api/v1/admin/session"

      patch_config(quantum: 240)

      expect(response).to have_http_status(:unauthorized)
      expect(store.reload.scheduler_config["quantum"]).to be_nil
    end
  end

  describe "GET /admin/prep_time_stats" do
    before { sign_in }

    it "is empty before the EWMA has anything to say" do
      get "/api/v1/admin/prep_time_stats"

      expect(body["items"]).to be_empty
    end

    # §7.3 requires 10 samples before the learned value overrides the seed.
    # Reporting confidence stops anyone reading a 3-sample average as truth.
    it "reports the learned value beside the seed, and whether to believe it" do
      menu_item = create(:menu_item, store: store, name: "Thai Tea", base_prep_seconds: 40)
      create(:prep_time_stat, menu_item: menu_item, ewma_seconds: 52.5, sample_count: 3)

      get "/api/v1/admin/prep_time_stats"

      expect(body["items"].first).to include(
        "name" => "Thai Tea",
        "seeded_prep_seconds" => 40,
        "ewma_seconds" => 52.5,
        "sample_count" => 3,
        "confident" => false,
        "minimum_samples" => 10
      )
    end

    it "excludes other stores" do
      other = create(:menu_item, store: create(:store), name: "Not Ours")
      create(:prep_time_stat, menu_item: other, sample_count: 20)

      get "/api/v1/admin/prep_time_stats"

      expect(body["items"]).to be_empty
    end
  end
end
