# Fails loudly if the test database carries data before any example runs.
#
# Transactional fixtures roll back everything a spec creates, so the only way
# rows survive into a run is someone seeding the test database — `db:prepare`
# does exactly that on a fresh database. The symptom is otherwise baffling:
# v1 resolves the current store as `Store.first` (§16 leaves multi-store routing
# open), so a seeded store silently outranks the one a request spec just built
# and every endpoint 404s or returns the wrong menu.
RSpec.configure do |config|
  config.before(:suite) do
    residue = [ Store, Order, OrderItem, MenuItem ].select(&:exists?)

    next if residue.empty?

    abort <<~MESSAGE
      The test database is not empty: #{residue.map(&:name).join(', ')} already have rows.

      Seed data in the test database shadows records created by specs. Reset with:

        RAILS_ENV=test bin/rails db:test:prepare

      Use `db:test:prepare` rather than `db:prepare` — the latter seeds a freshly
      created database.
    MESSAGE
  end
end
