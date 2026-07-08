# lib/bench/digests.rb
module Bench
  class Digests
    FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED
      FROM performance_schema.events_statements_summary_by_digest
      WHERE SCHEMA_NAME = 'bench'
      ORDER BY SUM_TIMER_WAIT DESC
      LIMIT 20
    SQL

    def initialize(client:)
      @client = client
    end

    # Zero the digest table. Called after workers register, before enqueue starts,
    # so captured stats cover steady-state benchmark activity only.
    def reset
      @client.query("TRUNCATE performance_schema.events_statements_summary_by_digest")
    end

    def fetch
      @client.query(FETCH_SQL).map do |text, count, total_ms, rows_examined|
        { digest_text: text, count: count.to_i, total_ms: total_ms.to_f, rows_examined: rows_examined.to_i }
      end
    end
  end
end
