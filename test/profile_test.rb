# test/profile_test.rb
require "test_helper"
require "bench/profile"

class ProfileTest < Minitest::Test
  def test_loads_default_profile_by_name
    p = Bench::Profile.load("default")
    assert_equal 1.0, p.mysql_cpus
    assert_equal "1g", p.mysql_memory
    assert_equal 10, p.workers
    assert_equal 2, p.threads
    assert_equal 0.1, p.polling_interval
    assert_equal 1, p.dispatchers
  end

  def test_cli_overrides_win
    p = Bench::Profile.load("default", workers: 50, mysql_cpus: 2.0)
    assert_equal 50, p.workers
    assert_equal 2.0, p.mysql_cpus
    assert_equal 2, p.threads # untouched
  end

  def test_env_map
    p = Bench::Profile.load("smoke")
    assert_equal(
      {
        "BENCH_MYSQL_CPUS" => "1.0",
        "BENCH_MYSQL_MEMORY" => "1g",
        "BENCH_WORKER_PROCESSES" => "2",
        "BENCH_WORKER_THREADS" => "2",
        "BENCH_POLLING_INTERVAL" => "0.1"
      },
      p.env
    )
  end

  def test_expected_process_count
    p = Bench::Profile.load("default")
    assert_equal 12, p.expected_process_count # 1 supervisor + 10 workers + 1 dispatcher
  end

  def test_to_h_roundtrips_for_result_json
    p = Bench::Profile.load("default")
    h = p.to_h
    assert_equal "default", h[:name]
    assert_equal 10, h[:workers]
    assert_equal 1, h[:dispatchers]
  end
end
