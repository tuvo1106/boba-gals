require "rails_helper"

RSpec.describe BuildSchedulerConfig do
  # §6.6 keys that are deliberately not scheduler settings: they belong to the
  # quality timer (§9.6) and the ETA projection (§7.1), and `Scheduler::Config`
  # has never carried them.
  NON_SCHEDULER_KEYS = %w[quality_limit_seconds eta_safety_factor].freeze

  describe "the translation" do
    it "maps this shop's §6.6 settings onto the scheduler's own vocabulary" do
      config = described_class.call(
        "cohesion_enabled" => true, "cohesion_boost" => 0.3,
        "remake_multiplier" => 9.0, "promise_buffer" => 45
      )

      expect(config).to have_attributes(
        staleness_enabled: true, staleness_boost: 0.3,
        expedited_multiplier: 9.0, deadline_buffer: 45
      )
    end

    it "passes through the keys both vocabularies already agree on" do
      config = described_class.call("policy" => "fifo", "quantum" => 240, "aging_rate" => 0.4)

      expect(config).to have_attributes(policy: :fifo, quantum: 240, aging_rate: 0.4)
    end

    # `Simulator::Scenario` builds symbol-keyed hashes; `Store` produces
    # string-keyed ones. Both go through here.
    it "accepts symbol keys as well as strings" do
      expect(described_class.call(cohesion_boost: 0.5).staleness_boost).to eq(0.5)
    end

    # Asserting `not_to respond_to(:quality_limit_seconds)` would prove nothing:
    # `Config` builds its readers from `DEFAULTS`, so that is true however the
    # adapter behaves. What actually needs holding is that these keys cannot
    # reach a scheduler setting *under some other name* — a `KEY_MAP` typo
    # pointing `quality_limit_seconds` at `deadline_buffer` would be silent
    # otherwise.
    it "drops the §6.6 keys the scheduler must not read, rather than rerouting them" do
      config = described_class.call("quality_limit_seconds" => 999, "eta_safety_factor" => 9.99)

      DeficitScheduler::Config::DEFAULTS.each do |key, default|
        expect(config.public_send(key)).to eq(default),
          "#{key} became #{config.public_send(key).inspect}; a non-scheduler key leaked into it"
      end
    end
  end

  # The point of these two: `KEY_MAP` is the only place the app's vocabulary and
  # the gem's meet, so a key added to either side without the other is a silent
  # misconfiguration — the scheduler would quietly run on a default while the
  # dashboard showed the operator's setting. These make that unmergeable.
  describe "the map is total, so the two vocabularies cannot drift apart" do
    it "feeds every setting the scheduler actually reads" do
      translated = Store::SCHEDULER_DEFAULTS.keys.map { |k| described_class::KEY_MAP.fetch(k.to_s, k.to_sym) }

      expect(DeficitScheduler::Config::DEFAULTS.keys - translated).to be_empty,
        "the scheduler reads settings nothing in Store::SCHEDULER_DEFAULTS feeds it"
    end

    it "sends every §6.6 setting somewhere the scheduler recognises" do
      unroutable = Store::SCHEDULER_DEFAULTS.keys.reject do |key|
        NON_SCHEDULER_KEYS.include?(key) ||
          DeficitScheduler::Config::DEFAULTS.key?(described_class::KEY_MAP.fetch(key.to_s, key.to_sym))
      end

      expect(unroutable).to be_empty,
        "these §6.6 settings reach the scheduler under a name it does not read: #{unroutable.inspect}"
    end

    # Catches a mis-wired entry that is still *total* — mapping cohesion_boost
    # onto deadline_buffer would pass both checks above and silently retune the
    # scheduler.
    it "carries this shop's shipped defaults through unchanged" do
      config = described_class.call(Store::SCHEDULER_DEFAULTS)

      DeficitScheduler::Config::DEFAULTS.each do |key, default|
        expect(config.public_send(key)).to eq(default),
          "#{key} arrived as #{config.public_send(key).inspect}, not the shipped #{default.inspect}"
      end
    end
  end
end
