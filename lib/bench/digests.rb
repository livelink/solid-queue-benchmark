# lib/bench/digests.rb
module Bench
  class Digests
    def initialize(client:, reset_sql:, fetch_sql:)
      @client = client
      @reset_sql = reset_sql
      @fetch_sql = fetch_sql
    end

    # Zero the digest table/stats. Called after workers register, before enqueue starts,
    # so captured stats cover steady-state benchmark activity only.
    def reset
      @client.query(@reset_sql)
    end

    def fetch
      @client.query(@fetch_sql).map do |text, count, total_ms, rows_examined|
        { digest_text: text, count: count.to_i, total_ms: total_ms.to_f, rows_examined: rows_examined.to_i }
      end
    end
  end
end
