module Api
  module V1
    module Admin
      class SchedulerConfigController < BaseController
        # GET /api/v1/admin/scheduler_config
        def show
          render json: payload
        end

        # PATCH /api/v1/admin/scheduler_config
        #
        # The dashboard's "Apply to store" action (§10.6). Deliberately not
        # silent: the response returns the config that is now live so the UI can
        # show what actually changed rather than what it hoped would.
        def update
          result = UpdateSchedulerConfig.new.call(store: current_store, changes: config_params)

          return unprocessable(result.errors) unless result.success?

          render json: payload
        end

        private

        def payload
          {
            store_id: current_store.id,
            # Effective, not raw: a key added to §6.6 after this store was
            # configured would otherwise read as absent rather than as its
            # default, and the dashboard would render a blank control.
            scheduler_config: current_store.effective_scheduler_config,
            editable: UpdateSchedulerConfig::SCHEMA.keys
          }
        end

        # Deliberately unfiltered. `params.expect` would *drop* unknown keys
        # silently, and the whole point of UpdateSchedulerConfig's allowlist is
        # to reject them loudly — a dashboard sending `quantam: 90` should be
        # told, not quietly ignored while nothing changes.
        #
        # Nothing is mass-assigned from this: the service writes only the values
        # it coerced against its own schema.
        def config_params
          raw = params[:scheduler_config]

          raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
        end
      end
    end
  end
end
