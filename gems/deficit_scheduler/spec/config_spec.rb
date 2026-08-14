require_relative "spec_helper"

RSpec.describe DeficitScheduler::Config do
  it "defaults to every §6.6 value" do
    expect(described_class.new).to have_attributes(
      policy: :drr, quantum: 60, aging_enabled: true, aging_rate: 0.15,
      staleness_enabled: false, staleness_boost: 1.0, expedited_multiplier: 4.0,
      deadline_buffer: 120
    )
  end

  it "takes overrides" do
    expect(described_class.new(quantum: 300).quantum).to eq(300)
  end

  describe ".from_h" do
    # The bridge from `stores.scheduler_config`, which has string keys.
    it "reads the store's string-keyed config" do
      config = described_class.from_h("quantum" => 240, "aging_rate" => 0.3)

      expect(config.quantum).to eq(240)
      expect(config.aging_rate).to eq(0.3)
    end

    it "symbolizes the policy so `fifo?` works on a string from the database" do
      expect(described_class.from_h("policy" => "fifo").fifo?).to be(true)
    end

    # The store carries quality_limit_seconds and eta_safety_factor, which
    # belong to the quality timer (§9.6) and the ETA (§7.1). The scheduler must
    # not grow opinions about either.
    it "ignores keys the scheduler has no business reading" do
      config = described_class.from_h(
        "quantum" => 240, "quality_limit_seconds" => 300, "eta_safety_factor" => 1.15
      )

      expect(config.quantum).to eq(240)
      expect(config).not_to respond_to(:quality_limit_seconds)
    end

    it "falls back to defaults for keys the store never set" do
      expect(described_class.from_h("quantum" => 240).aging_rate).to eq(0.15)
    end
  end

  describe "#fifo?" do
    it "is true only for the §6.3 control arm" do
      expect(described_class.new(policy: :fifo).fifo?).to be(true)
      expect(described_class.new(policy: :drr).fifo?).to be(false)
    end
  end
end
