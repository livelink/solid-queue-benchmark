# lib/bench/mysql_client.rb
require "bench/shell"

module Bench
  class MysqlClient
    BASE_CMD = %w[docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e].freeze

    def initialize(runner: Shell.method(:capture))
      @runner = runner
    end

    def query(sql)
      out = @runner.call(BASE_CMD + [sql], env: {})
      out.split("\n").map { |line| line.split("\t") }
    end

    def scalar(sql)
      query(sql).dig(0, 0)
    end
  end
end
