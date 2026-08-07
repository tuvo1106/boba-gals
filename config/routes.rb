Rails.application.routes.draw do
  # Liveness and readiness for the kubelet (§14.3). Not the same thing as
  # /api/v1/health, which is business-level.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      # Ordering — kiosk and web (§9.1)
      get "menu", to: "menu#index"
      get "health", to: "health#show"

      resources :orders, only: [ :create ]

      # The pickup code is the capability token, not an id (§13.1). Constrained
      # to the 4-character unambiguous alphabet so junk never reaches the query.
      get "orders/:pickup_code", to: "orders#show",
          constraints: { pickup_code: /[A-Za-z0-9]{4}/ }
    end
  end
end
