# test/engines_test.rb
require "test_helper"
require "bench/engines"

class EnginesTest < Minitest::Test
  def test_names
    assert_equal %w[mysql postgres], Bench::Engines.names
  end

  def test_mysql_entry
    engine = Bench::Engines.fetch("mysql")
    assert_equal Bench::MysqlClient, engine.client_class
    assert_equal "sq-bench-mysql", engine.container
    assert_equal "mysql", engine.service
    assert_equal "BENCH_MYSQL_PORT", engine.port_env
    assert_equal 13306, engine.default_port
    assert_includes engine.digest_fetch_sql, "performance_schema"
    assert_includes engine.digest_reset_sql, "TRUNCATE"
  end

  def test_postgres_entry
    engine = Bench::Engines.fetch("postgres")
    assert_equal Bench::PostgresClient, engine.client_class
    assert_equal "sq-bench-postgres", engine.container
    assert_equal "postgres", engine.service
    assert_equal "BENCH_POSTGRES_PORT", engine.port_env
    assert_equal 15432, engine.default_port
    assert_includes engine.digest_fetch_sql, "pg_stat_statements"
    assert_includes engine.digest_reset_sql, "pg_stat_statements_reset"
  end

  def test_fetch_unknown_raises
    err = assert_raises(ArgumentError) { Bench::Engines.fetch("bogus") }
    assert_includes err.message, "bogus"
  end
end
