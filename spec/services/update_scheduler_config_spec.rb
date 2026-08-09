require "rails_helper"

RSpec.describe UpdateSchedulerConfig do
  # A store that has been PATCHed must still follow future default changes.
  #
  # Merging into `effective_scheduler_config` materialised all ten keys, so one
  # admin touching one setting pinned the store to that day's defaults forever —
  # which is how §10.5's quantum change would have reached no store anyone had
  # ever configured.
  describe "what actually gets stored (§6.6)" do
    let(:store) { create(:store) }

    it "stores only the keys that were set" do
      described_class.new.call(store: store, changes: { "quantum" => 90 })

      expect(store.reload.scheduler_config).to eq("quantum" => 90)
    end

    it "leaves every other key following the default" do
      described_class.new.call(store: store, changes: { "quantum" => 90 })

      expect(store.reload.effective_scheduler_config)
        .to include("aging_rate" => Store::SCHEDULER_DEFAULTS["aging_rate"])
    end

    # The reason the merge exists at all: a PATCH naming one key must not reset
    # the others that were genuinely set earlier.
    it "keeps an earlier explicit setting when a later PATCH names something else" do
      described_class.new.call(store: store, changes: { "quantum" => 90 })
      described_class.new.call(store: store, changes: { "aging_rate" => 0.5 })

      expect(store.reload.scheduler_config).to eq("quantum" => 90, "aging_rate" => 0.5)
    end

    it "picks up a later change to the defaults for a key nobody set" do
      described_class.new.call(store: store, changes: { "quantum" => 90 })

      stub_const("Store::SCHEDULER_DEFAULTS",
                 Store::SCHEDULER_DEFAULTS.merge("promise_buffer" => 999))

      expect(store.reload.effective_scheduler_config["promise_buffer"]).to eq(999)
    end
  end

  let(:store) { create(:store) }

  def apply(changes)
    described_class.new.call(store: store, changes: changes)
  end

  describe "coercion" do
    it "accepts numbers sent as JSON strings, the way an HTML form would" do
      expect(apply("quantum" => "240")).to be_success
      expect(store.reload.scheduler_config["quantum"]).to eq(240)
    end

    # Integer("12abc") is nil rather than 12. A partial parse would accept a
    # typo and apply whichever prefix happened to parse.
    it "rejects a number with trailing junk instead of parsing the prefix" do
      result = apply("quantum" => "240abc")

      expect(result).not_to be_success
      expect(result.errors.join).to include("quantum must be a number")
    end

    it "keeps integers and floats in their own types" do
      apply("quantum" => "240", "eta_safety_factor" => "1.4")

      config = store.reload.scheduler_config
      expect(config["quantum"]).to be_a(Integer)
      expect(config["eta_safety_factor"]).to be_a(Float)
    end

    # "maybe" is a mistake, and coercing it to false would apply a scheduler
    # change nobody asked for.
    it "accepts only real booleans and their two string spellings" do
      expect(apply("aging_enabled" => false)).to be_success
      expect(apply("aging_enabled" => "true")).to be_success
      expect(apply("aging_enabled" => "maybe")).not_to be_success
      expect(apply("aging_enabled" => 1)).not_to be_success
    end

    it "rejects a policy that is not one of the two the design defines" do
      expect(apply("policy" => "fifo")).to be_success
      expect(apply("policy" => "drr")).to be_success
      expect(apply("policy" => "lifo")).not_to be_success
    end

    # §6.3's comparison arms exist in `Scheduler::Config::POLICIES` and run in
    # the simulator. SJF minimises mean wait by starving large orders — the
    # failure §1 exists to prevent — so the store must refuse it even though the
    # scheduler can execute it.
    it "refuses the simulator-only comparison arms" do
      expect(Scheduler::Config::POLICIES).to include(:rr, :sjf)

      expect(apply("policy" => "rr")).not_to be_success
      expect(apply("policy" => "sjf")).not_to be_success
    end
  end

  describe "bounds" do
    # Below 1.0 the priority *floor* (§6.4) becomes a ceiling and remakes rank
    # below same-age normal work — the exact inversion the multiplier exists to
    # prevent.
    it "will not let remake_multiplier invert the priority floor" do
      result = apply("remake_multiplier" => 0.5)

      expect(result).not_to be_success
      expect(result.errors.join).to include("remake_multiplier")
    end

    # Below 1.0 is deliberately under-quoting every customer, and §7.3 is blunt
    # about bias being what destroys trust in the board.
    it "will not let eta_safety_factor quote below the estimate" do
      expect(apply("eta_safety_factor" => 0.9)).not_to be_success
      expect(apply("eta_safety_factor" => 1.0)).to be_success
    end

    it "rejects a quantum outside the sweep range" do
      expect(apply("quantum" => 0)).not_to be_success
      expect(apply("quantum" => 10_000)).not_to be_success
    end

    it "accepts every §6.6 default" do
      expect(apply(Store::SCHEDULER_DEFAULTS)).to be_success
    end
  end

  describe "the allowlist" do
    # §14.6: scheduler_config is runtime tuning and must never hold a secret.
    # An allowlist is the only version of that rule that cannot be forgotten.
    it "rejects unknown keys" do
      result = apply("twilio_auth_token" => "sk-live-oops")

      expect(result).not_to be_success
      expect(result.errors.join).to include("twilio_auth_token")
    end

    it "names every unknown key, not just the first" do
      result = apply("nope" => 1, "also_nope" => 2)

      expect(result.errors.join).to include("also_nope", "nope")
    end

    it "writes nothing when one key of several is bad" do
      apply("quantum" => 240, "policy" => "lifo")

      expect(store.reload.scheduler_config).to be_empty
    end
  end

  it "merges rather than replacing" do
    store.update!(scheduler_config: { "quantum" => 90, "aging_rate" => 0.3 })

    apply("quantum" => 150)

    expect(store.reload.scheduler_config).to include("quantum" => 150, "aging_rate" => 0.3)
  end

  # Asserted on the *effective* config rather than the stored column. Storing
  # the defaults was how this used to be achieved, and it is exactly what pinned
  # a configured store to the defaults of the day it was configured — see "what
  # actually gets stored" above. What matters is that every key resolves, not
  # where it resolves from.
  it "resolves §6.6 defaults for keys the store never set" do
    apply("quantum" => 150)

    expect(store.reload.effective_scheduler_config)
      .to include(Store::SCHEDULER_DEFAULTS.except("quantum"))
  end

  it "accepts symbol keys" do
    expect(apply(quantum: 300)).to be_success
  end
end
