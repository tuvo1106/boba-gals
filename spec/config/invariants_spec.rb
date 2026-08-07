require "rails_helper"

# Design invariants that hold for every change, enforced rather than attested.
#
# These started life as PR-checklist items. A checklist line that reads "n/a" on
# nine PRs out of ten teaches you to tick it without reading it, which is the
# failure mode checklists exist to prevent. A failing spec does not have that
# problem.
RSpec.describe "design invariants" do
  describe "ActionCable adapter (§14.4)" do
    # `web` runs 2 replicas from the first deploy (§14.2). The async adapter is
    # single-process: broadcasts from pod A never reach subscribers on pod B, and
    # nothing fails loudly — the board and KDS just quietly stop updating for
    # half the users.
    %w[development production].each do |env|
      it "is redis in #{env}" do
        config = Rails.application.config_for(:cable, env: env)

        expect(config[:adapter]).to eq("redis"),
          "cable.yml #{env} adapter is #{config[:adapter].inspect}; §14.4 requires redis"
      end
    end

    it "is the test adapter in test" do
      config = Rails.application.config_for(:cable, env: "test")

      expect(config[:adapter]).to eq("test")
    end

    # Declaring the adapter in cable.yml is not the same as being able to load
    # it. ActionCable constrains the redis gem (`>= 4, < 6` as of 8.1), and a
    # gem outside that range raises Gem::LoadError the first time anything
    # broadcasts — in development and production only, since test uses the test
    # adapter. That is a runtime failure the rest of the suite cannot see.
    it "can actually load the redis adapter, not just name it" do
      expect { require "action_cable/subscription_adapter/redis" }.not_to raise_error
      expect(defined?(ActionCable::SubscriptionAdapter::Redis)).to be_truthy
    end
  end

  # Sidekiq, not Solid Queue (§14.1). The test environment overrides the adapter
  # to :test, so the assertion has to read what the application sets rather than
  # what is currently in effect — the same reason the cable checks above go
  # through config_for.
  describe "background jobs (§14.1)" do
    it "configures Sidekiq as the ActiveJob adapter" do
      application = Rails.root.join("config/application.rb").read

      expect(application).to match(/config\.active_job\.queue_adapter\s*=\s*:sidekiq/)
    end

    # Naming an adapter is not the same as being able to load it — the lesson
    # from the redis pin above, which passed every spec and failed on the first
    # real broadcast.
    it "can actually load the sidekiq adapter" do
      expect { require "active_job/queue_adapters/sidekiq_adapter" }.not_to raise_error
      expect(defined?(ActiveJob::QueueAdapters::SidekiqAdapter)).to be_truthy
    end
  end

  describe "customer_phone hygiene (§13.5)" do
    it "is filtered from logs" do
      expect(Rails.application.config.filter_parameters).to include(:customer_phone)
    end
  end

  describe "migrations do not run on container boot (§14.2)" do
    # Migrations belong to the `migrate` Job applied before each rollout. With 2
    # web replicas, a boot-time migration means two pods racing the same schema
    # change, and a crash-looping pod retries it indefinitely.
    it "keeps bin/docker-entrypoint free of schema commands" do
      entrypoint = Rails.root.join("bin/docker-entrypoint").read

      expect(entrypoint).not_to match(/db:(prepare|migrate|setup|schema)/)
    end
  end
end
