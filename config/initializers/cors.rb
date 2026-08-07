# The React app is served from a different origin than the API in development —
# Vite on :5173, Rails on :3000. In production the ingress puts both behind one
# host, routing /api and /cable to `web` and everything else to `frontend`
# (§14.2), so no cross-origin request happens and no origin is allowed here.
if Rails.env.development? || Rails.env.test?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins "http://localhost:5173", "http://127.0.0.1:5173"
      resource "/api/*", headers: :any, methods: [ :get, :post, :patch, :delete, :options ]
    end
  end
end
