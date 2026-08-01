# test/digests_test.rb
require "test_helper"
require "bench/digests"

class DigestsTest < Minitest::Test
  FakeClient = Struct.new(:rows) do
    def query(sql) = rows
  end

  def test_fetch_maps_mysql_style_rows
    rows = [["SELECT * FROM `solid_queue_ready_executions` ...", "1500", "2345.6", "150000"]]
    digests = Bench::Digests.new(
      client: FakeClient.new(rows),
      reset_sql: "TRUNCATE performance_schema.events_statements_summary_by_digest",
      fetch_sql: "SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED " \
                 "FROM performance_schema.events_statements_summary_by_digest"
    )
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM `solid_queue_ready_executions` ...", result[0][:digest_text]
    assert_equal 1500, result[0][:count]
    assert_equal 2345.6, result[0][:total_ms]
    assert_equal 150_000, result[0][:rows_examined]
  end

  def test_fetch_maps_postgres_style_rows
    rows = [["SELECT * FROM pg_stat_statements ...", "42", "10.5", "9000"]]
    digests = Bench::Digests.new(
      client: FakeClient.new(rows),
      reset_sql: "SELECT pg_stat_statements_reset()",
      fetch_sql: "SELECT query, calls, ROUND(total_exec_time, 1), rows FROM pg_stat_statements"
    )
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM pg_stat_statements ...", result[0][:digest_text]
    assert_equal 42, result[0][:count]
    assert_equal 10.5, result[0][:total_ms]
    assert_equal 9000, result[0][:rows_examined]
  end

  def test_reset_issues_the_given_sql
    recorder = Struct.new(:queries) do
      def query(sql)
        queries << sql
        []
      end
    end.new([])
    digests = Bench::Digests.new(
      client: recorder,
      reset_sql: "SELECT pg_stat_statements_reset()",
      fetch_sql: "SELECT 1"
    )
    digests.reset
    assert_equal ["SELECT pg_stat_statements_reset()"], recorder.queries
  end
end
