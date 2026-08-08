require "rails_helper"

RSpec.describe Station do
  # §7.2 lists station activation as an ETA recompute trigger, and it is the one
  # with the largest effect: capacity is the divisor in every projection, so
  # opening a fourth bar changes every number on the board at once.
  describe "recomputing ETAs on activation (§7.2)" do
    let(:store) { create(:store, :with_stations) }

    it "recomputes when a station is deactivated" do
      expect(RecomputeEta).to receive(:call).with(store)

      store.stations.first.update!(active: false)
    end

    it "recomputes when a station is activated" do
      station = store.stations.first
      station.update!(active: false)

      expect(RecomputeEta).to receive(:call).with(store)
      station.update!(active: true)
    end

    # Renaming a bar does not change capacity, and the projection is expensive
    # enough (ADR-0012) that firing it on every save would matter.
    it "does not recompute when something other than active changes" do
      expect(RecomputeEta).not_to receive(:call)

      store.stations.first.update!(name: "Bar Renamed")
    end
  end
end
