require "rails_helper"

RSpec.describe Store do
  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to have_many(:menu_items).dependent(:destroy) }

  describe "#effective_scheduler_config" do
    it "supplies the §6.6 defaults for an unconfigured store" do
      expect(create(:store).effective_scheduler_config).to include(
        "policy" => "drr", "quantum" => 60, "aging_rate" => 0.15, "remake_multiplier" => 4.0
      )
    end

    it "lets a stored value win over its default" do
      store = create(:store, scheduler_config: { "quantum" => 240 })

      config = store.effective_scheduler_config

      expect(config["quantum"]).to eq(240)
      expect(config["policy"]).to eq("drr"), "unset keys still fall back to the design defaults"
    end

    # FIFO is kept implemented permanently as the simulator's control arm and the
    # production fallback if DRR misbehaves (§6.3).
    it "can be switched to the fifo control policy" do
      store = create(:store, scheduler_config: { "policy" => "fifo" })

      expect(store.effective_scheduler_config["policy"]).to eq("fifo")
    end
  end

  describe "#active_stations" do
    # Runtime capacity is active stations, not the station_count seed (§4.1).
    it "ignores deactivated stations" do
      store = create(:store, station_count: 3)
      live = create(:station, store: store)
      create(:station, :inactive, store: store)

      expect(store.active_stations).to contain_exactly(live)
    end
  end
end
