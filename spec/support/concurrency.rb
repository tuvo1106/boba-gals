# Real concurrency needs real connections.
#
# RSpec's transactional fixtures wrap each example in one connection's
# transaction, which makes `FOR UPDATE SKIP LOCKED` (§8) untestable: other
# threads can't see the uncommitted rows, so the very contention the lock exists
# to resolve never happens. Examples tagged `:no_transaction` opt out and clean
# up by truncation instead.
RSpec.configure do |config|
  config.around(:each, :no_transaction) do |example|
    self.use_transactional_tests = false
    example.run
    self.use_transactional_tests = true

    # Truncate rather than delete so sequences reset too, keeping ids
    # predictable across examples.
    tables = ActiveRecord::Base.connection.tables - [ "schema_migrations", "ar_internal_metadata" ]
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{tables.map { |t| ActiveRecord::Base.connection.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE"
    )
  end

  # Threads in a concurrency example each check out their own connection; the
  # pool must be large enough or they serialize and prove nothing.
  config.before(:suite) do
    pool_size = ActiveRecord::Base.connection_pool.size
    warn "\nWARNING: connection pool is #{pool_size}; concurrency specs want >= 8\n" if pool_size < 8
  end
end
