# test/progress_reporter_test.rb
require "test_helper"
require "bench/progress_reporter"

class ProgressReporterFormatDurationTest < Minitest::Test
  def test_formats_seconds_only
    assert_equal "0s", Bench::ProgressReporter.format_duration(0)
    assert_equal "45s", Bench::ProgressReporter.format_duration(45)
  end

  def test_formats_minutes_and_seconds
    assert_equal "1m 30s", Bench::ProgressReporter.format_duration(90)
  end

  def test_formats_hours_minutes_and_seconds
    assert_equal "1h 1m 1s", Bench::ProgressReporter.format_duration(3661)
  end

  def test_rounds_fractional_seconds
    assert_equal "1m 30s", Bench::ProgressReporter.format_duration(89.6)
  end
end
