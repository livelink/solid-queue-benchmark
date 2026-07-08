# test/scenarios_test.rb
require "test_helper"
require "bench/scenarios"

class ScenariosTest < Minitest::Test
  def test_baseline_defaults
    s = Bench::Scenarios.build("baseline", {})
    assert_equal({ "jobs" => 20_000, "rate" => 500, "work_ms" => 50, "duration" => 60 }, s.params)
    assert_equal 20_000, s.expected_total
  end

  def test_baseline_param_overrides_are_typed
    s = Bench::Scenarios.build("baseline", { "jobs" => "100", "work_ms" => "0" })
    assert_equal 100, s.params["jobs"]
    assert_equal 0, s.params["work_ms"]
    assert_equal 100, s.expected_total
  end

  def test_baseline_idle_variant
    s = Bench::Scenarios.build("baseline", { "jobs" => "0" })
    assert_equal 0, s.expected_total
  end

  def test_sprawl_expected_total_is_geometric
    s = Bench::Scenarios.build("sprawl", {})
    # 100 seeds * (1 + 50 + 50^2) = 255,100
    assert_equal 255_100, s.expected_total
    small = Bench::Scenarios.build("sprawl", { "seeds" => "2", "fanout" => "3", "depth" => "1" })
    assert_equal 8, small.expected_total # 2 * (1 + 3)
  end

  def test_unknown_scenario_raises
    assert_raises(ArgumentError) { Bench::Scenarios.build("nope", {}) }
  end

  def test_baseline_zero_rate_raises_when_jobs_positive
    err = assert_raises(ArgumentError) { Bench::Scenarios.build("baseline", { "rate" => "0" }) }
    assert_includes err.message, "rate"
  end

  def test_baseline_zero_rate_allowed_for_idle_variant
    s = Bench::Scenarios.build("baseline", { "jobs" => "0", "rate" => "0" })
    assert_equal 0, s.expected_total
  end

  def test_non_integer_param_value_raises
    err = assert_raises(ArgumentError) { Bench::Scenarios.build("baseline", { "jobs" => "abc" }) }
    assert_includes err.message, "jobs"
  end

  def test_unknown_param_raises
    assert_raises(ArgumentError) { Bench::Scenarios.build("baseline", { "bogus" => "1" }) }
  end

  def test_names
    assert_equal %w[baseline sprawl], Bench::Scenarios.names
  end
end
