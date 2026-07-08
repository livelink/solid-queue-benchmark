# harness/script/db_setup.rb
db_config = ActiveRecord::Base.connection_db_config.configuration_hash

ActiveRecord::Base.establish_connection(db_config.merge(database: nil))
ActiveRecord::Base.connection.execute("CREATE DATABASE IF NOT EXISTS #{db_config[:database]}")
ActiveRecord::Base.establish_connection(db_config)

gem_path = Gem.loaded_specs["solid_queue"].full_gem_path
schema_candidates = [
  File.join(gem_path, "db", "queue_schema.rb"),
  File.join(gem_path, "lib", "generators", "solid_queue", "install", "templates", "db", "queue_schema.rb")
]
queue_schema = schema_candidates.find { |path| File.exist?(path) }
raise "Could not find solid_queue queue_schema.rb (looked in: #{schema_candidates.join(', ')})" unless queue_schema
load queue_schema

ActiveRecord::Schema.define do
  create_table :bench_events, force: true do |t|
    t.string :job_id, null: false
    t.string :job_class, null: false
    t.string :queue_name
    t.integer :priority, default: 0
    t.datetime :enqueued_at, precision: 6
    t.datetime :started_at, precision: 6
    t.datetime :finished_at, precision: 6
  end
end

puts "db_setup: ok (solid_queue schema from #{queue_schema})"
