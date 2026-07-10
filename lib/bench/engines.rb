# lib/bench/engines.rb
require "bench/mysql_client"
require "bench/postgres_client"

module Bench
  module Engines
    Engine = Struct.new(
      :name, :client_class, :container, :service, :port_env, :default_port,
      :digest_reset_sql, :digest_fetch_sql,
      keyword_init: true
    )

    MYSQL_DIGEST_FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED
      FROM performance_schema.events_statements_summary_by_digest
      WHERE SCHEMA_NAME = 'bench'
      ORDER BY SUM_TIMER_WAIT DESC
      LIMIT 20
    SQL

    POSTGRES_DIGEST_FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT query, calls, ROUND(total_exec_time::numeric, 1), rows
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'bench')
      ORDER BY total_exec_time DESC
      LIMIT 20
    SQL

    REGISTRY = {
      "mysql" => Engine.new(
        name: "mysql",
        client_class: MysqlClient,
        container: "sq-bench-mysql",
        service: "mysql",
        port_env: "BENCH_MYSQL_PORT",
        default_port: 13306,
        digest_reset_sql: "TRUNCATE performance_schema.events_statements_summary_by_digest",
        digest_fetch_sql: MYSQL_DIGEST_FETCH_SQL
      ),
      "postgres" => Engine.new(
        name: "postgres",
        client_class: PostgresClient,
        container: "sq-bench-postgres",
        service: "postgres",
        port_env: "BENCH_POSTGRES_PORT",
        default_port: 15432,
        digest_reset_sql: "SELECT pg_stat_statements_reset()",
        digest_fetch_sql: POSTGRES_DIGEST_FETCH_SQL
      )
    }.freeze

    def self.fetch(name)
      REGISTRY.fetch(name) do
        raise ArgumentError, "unknown database #{name.inspect} (available: #{names.join(", ")})"
      end
    end

    def self.names = REGISTRY.keys
  end
end
