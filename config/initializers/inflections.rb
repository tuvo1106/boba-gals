ActiveSupport::Inflector.inflections(:en) do |inflect|
  # ActiveSupport pluralizes "barista" to "barista" — the default rules read the
  # trailing "-ista" as already plural. Without this, `t.references :barista`
  # looks for a table named "barista" and Barista.table_name is wrong too, so
  # fixing it at the inflector rather than per-call-site is the only version
  # that holds everywhere.
  inflect.irregular "barista", "baristas"
end
