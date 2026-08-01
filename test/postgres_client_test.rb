# test/postgres_client_test.rb
require "test_helper"
require "bench/postgres_client"

class PostgresClientTest < Minitest::Test
  def test_query_parses_csv_rows
    fake = lambda do |cmd, env: {}|
      assert_equal %w[docker compose exec -T postgres psql -U bench -d bench -t --csv -c], cmd[0..-2]
      assert_equal "SELECT 1, 'a'", cmd.last
      "1,a\n2,b\n"
    end
    client = Bench::PostgresClient.new(runner: fake)
    assert_equal [["1", "a"], ["2", "b"]], client.query("SELECT 1, 'a'")
  end

  def test_query_handles_multiline_field_values
    fake = ->(_cmd, env: {}) { "1,\"line1\nline2\",3\n" }
    client = Bench::PostgresClient.new(runner: fake)
    assert_equal [["1", "line1\nline2", "3"]], client.query("SELECT 1, 'line1\nline2', 3")
  end

  def test_scalar
    client = Bench::PostgresClient.new(runner: ->(_cmd, env: {}) { "42\n" })
    assert_equal "42", client.scalar("SELECT COUNT(*) FROM t")
  end

  def test_scalar_nil_on_empty
    client = Bench::PostgresClient.new(runner: ->(_cmd, env: {}) { "" })
    assert_nil client.scalar("SELECT 1 WHERE FALSE")
  end
end
