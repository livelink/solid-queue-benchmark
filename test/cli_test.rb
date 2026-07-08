# test/cli_test.rb
require "test_helper"
require "bench/cli"

class CliTest < Minitest::Test
  def test_parse_run_options
    opts = Bench::CLI.parse_run_options(%w[
      baseline --source path:/x/solid_queue --profile smoke
      --set jobs=100 --set work_ms=0 --workers 4 --timeout 60 --allow-dirty --repeat 2
    ])
    assert_equal "baseline", opts[:scenario]
    assert_equal "path:/x/solid_queue", opts[:source]
    assert_equal "smoke", opts[:profile]
    assert_equal({ "jobs" => "100", "work_ms" => "0" }, opts[:params])
    assert_equal 4, opts[:overrides][:workers]
    assert_equal 60, opts[:timeout]
    assert_equal 2, opts[:repeat]
    assert opts[:allow_dirty]
  end

  def test_run_requires_scenario_and_source
    assert_raises(ArgumentError) { Bench::CLI.parse_run_options(%w[--source upstream]) }
    assert_raises(ArgumentError) { Bench::CLI.parse_run_options(%w[baseline]) }
  end

  def test_rejects_malformed_set
    assert_raises(ArgumentError) do
      Bench::CLI.parse_run_options(%w[baseline --source upstream --set jobs])
    end
  end

  def test_repeat_must_be_positive
    assert_raises(ArgumentError) do
      Bench::CLI.parse_run_options(%w[baseline --source upstream --repeat 0])
    end
  end
end
