# test/digests_test.rb
require "test_helper"
require "bench/digests"

class DigestsTest < Minitest::Test
  FakeClient = Struct.new(:rows) do
    def query(sql) = sql.start_with?("TRUNCATE") ? [] : rows
  end

  def test_fetch_maps_rows
    rows = [["SELECT * FROM `solid_queue_ready_executions` ...", "1500", "2345.6", "150000"]]
    digests = Bench::Digests.new(client: FakeClient.new(rows))
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM `solid_queue_ready_executions` ...", result[0][:digest_text]
    assert_equal 1500, result[0][:count]
    assert_equal 2345.6, result[0][:total_ms]
    assert_equal 150_000, result[0][:rows_examined]
  end
end
