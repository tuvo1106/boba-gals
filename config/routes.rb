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

      # Customer board — public (§9.5, §13.1).
      get "board", to: "board#show"

      # Kitchen display (§9.1). Everything below the session requires a station
      # token (§13.3).
      namespace :kds do
        post "session", to: "sessions#create"
        get "queue", to: "queue#show"

        # start takes no id — the server picks the next drink, which is what
        # lets the scheduler replace FIFO at step 5 without touching the client.
        post "items/start", to: "items#start"
        post "items/:id/finish", to: "items#finish"
        post "items/:id/undo", to: "items#undo"
      end

      # Admin (§9.1, §13.4). Cookie session, one user, no signup. This is behind
      # auth from the first deploy because PATCH scheduler_config changes live
      # scheduler behaviour.
      namespace :admin do
        post "session", to: "sessions#create"
        get "session", to: "sessions#show"
        delete "session", to: "sessions#destroy"

        get "scheduler_config", to: "scheduler_config#show"
        patch "scheduler_config", to: "scheduler_config#update"

        get "prep_time_stats", to: "prep_time_stats#index"
      end
    end
  end
end
