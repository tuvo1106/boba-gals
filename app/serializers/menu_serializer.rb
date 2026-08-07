# GET /api/v1/menu (§9.1) — items, option groups, availability.
#
# `min_select`/`max_select` travel to the client because they decide the control
# the ordering UI renders: a radio group when at most one may be chosen, a
# checkbox set otherwise (ADR-0003).
module MenuSerializer
  # @param store [Store]
  # @return [Hash]
  def self.call(store)
    items = store.menu_items.available.ordered.includes(option_groups: :options)

    { items: items.map { |item| serialize_item(item) } }
  end

  def self.serialize_item(item)
    {
      id: item.id,
      name: item.name,
      category: item.category,
      price_cents: item.price_cents,
      base_prep_seconds: item.base_prep_seconds,
      option_groups: item.option_groups.map { |group| serialize_group(group) }
    }
  end

  def self.serialize_group(group)
    {
      id: group.id,
      name: group.name,
      min_select: group.min_select,
      max_select: group.max_select,
      options: group.options.map do |option|
        {
          id: option.id,
          name: option.name,
          price_cents: option.price_cents,
          prep_seconds_delta: option.prep_seconds_delta
        }
      end
    }
  end
end
