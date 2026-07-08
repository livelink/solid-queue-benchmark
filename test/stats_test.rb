# test/stats_test.rb
require "test_helper"
require "bench/stats"

class StatsTest < Minitest::Test
  def test_percentile_interpolates
    values = [10.0, 20.0, 30.0, 40.0]
    assert_equal 25.0, Bench::Stats.percentile(values, 50)
    assert_equal 10.0, Bench::Stats.percentile(values, 0)
    assert_equal 40.0, Bench::Stats.percentile(values, 100)
    assert_in_delta 38.5, Bench::Stats.percentile(values, 95), 0.001
  end

  def test_percentile_handles_unsorted_and_empty
    assert_equal 25.0, Bench::Stats.percentile([40.0, 10.0, 30.0, 20.0], 50)
    assert_nil Bench::Stats.percentile([], 50)
  end

  def test_summary
    s = Bench::Stats.summary([10.0, 20.0, 30.0, 40.0])
    assert_equal 25.0, s[:p50]
    assert_equal 40.0, s[:max]
    assert_equal 25.0, s[:mean]
    assert_equal 4, s[:count]
  end

  def test_summary_empty
    assert_equal({ count: 0 }, Bench::Stats.summary([]))
  end

  def test_per_second_buckets
    # unix timestamps: three events in second 100, one in second 102
    ts = [100.1, 100.5, 100.9, 102.3]
    assert_equal [[100, 3], [101, 0], [102, 1]], Bench::Stats.per_second(ts)
    assert_equal [], Bench::Stats.per_second([])
  end
end
