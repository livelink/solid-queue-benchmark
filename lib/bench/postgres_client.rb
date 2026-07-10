# lib/bench/postgres_client.rb
require "csv"
require "bench/shell"

module Bench
  class PostgresClient
    # CSV (not plain tab-separated) because pg_stat_statements' query text can
    # span multiple lines (e.g. Rails' own multi-line introspection queries) -
    # a bare newline-per-row split would shred one row into several.
    BASE_CMD = %w[docker compose exec -T postgres psql -U bench -d bench -t --csv -c].freeze

    def initialize(runner: Shell.method(:capture))
      @runner = runner
    end

    def query(sql)
      out = @runner.call(BASE_CMD + [sql], env: {})
      CSV.parse(out)
    end

    def scalar(sql)
      query(sql).dig(0, 0)
    end
  end
end
