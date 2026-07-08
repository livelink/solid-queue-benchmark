# test/mysql_client_test.rb
require "test_helper"
require "bench/mysql_client"

class MysqlClientTest < Minitest::Test
  def test_query_parses_tsv_rows
    fake = lambda do |cmd, env: {}|
      assert_equal %w[docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e], cmd[0..-2]
      assert_equal "SELECT 1, 'a'", cmd.last
      "1\ta\n2\tb\n"
    end
    client = Bench::MysqlClient.new(runner: fake)
    assert_equal [["1", "a"], ["2", "b"]], client.query("SELECT 1, 'a'")
  end

  def test_scalar
    client = Bench::MysqlClient.new(runner: ->(_cmd, env: {}) { "42\n" })
    assert_equal "42", client.scalar("SELECT COUNT(*) FROM t")
  end

  def test_scalar_nil_on_empty
    client = Bench::MysqlClient.new(runner: ->(_cmd, env: {}) { "" })
    assert_nil client.scalar("SELECT 1 WHERE FALSE")
  end
end
