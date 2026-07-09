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

class ProgressReporterEtaSecondsTest < Minitest::Test
  def test_returns_nil_with_fewer_than_two_samples
    assert_nil Bench::ProgressReporter.eta_seconds([], 500)
    assert_nil Bench::ProgressReporter.eta_seconds([{ "t" => 0.0, "completed" => 0 }], 500)
  end

  def test_returns_nil_when_there_is_no_progress
    samples = [{ "t" => 0.0, "completed" => 10 }, { "t" => 5.0, "completed" => 10 }]
    assert_nil Bench::ProgressReporter.eta_seconds(samples, 500)
  end

  def test_returns_zero_when_target_already_reached
    samples = [{ "t" => 0.0, "completed" => 0 }, { "t" => 5.0, "completed" => 500 }]
    assert_equal 0.0, Bench::ProgressReporter.eta_seconds(samples, 500)
  end

  def test_computes_eta_from_a_steady_rate
    # t=0..14, completed +10/s -> steady 10 jobs/sec
    samples = (0..14).map { |t| { "t" => t.to_f, "completed" => t * 10 } }
    # default 12s window -> reference is t=2 (14-2=12), dc=140-20=120, dt=12 -> rate 10/s
    # remaining = 500-140 = 360 -> eta = 36.0s
    assert_in_delta 36.0, Bench::ProgressReporter.eta_seconds(samples, 500), 0.001
  end

  def test_eta_reflects_recent_window_not_overall_average
    slow = (0..9).map { |t| { "t" => t.to_f, "completed" => t } } # 1 job/sec
    fast = (10..20).map { |t| { "t" => t.to_f, "completed" => 9 + (t - 9) * 20 } } # 20 jobs/sec
    samples = slow + fast
    # latest: t=20, completed=229. overall average rate = 229/20 = 11.45/s -> naive ETA ~23.67s
    # 12s window -> reference t=8 (20-8=12), completed=8. dc=221, dt=12 -> rate ~18.417/s
    # remaining = 500-229 = 271 -> eta = 271 / (221.0/12) = 14.71493...s
    eta = Bench::ProgressReporter.eta_seconds(samples, 500)
    assert_in_delta 14.7149, eta, 0.001
    assert_operator eta, :<, 20.0 # meaningfully faster than the naive overall-average ETA (~23.67s)
  end
end

class ProgressReporterFormatLineTest < Minitest::Test
  def test_formats_line_with_eta
    line = Bench::ProgressReporter.format_line(1234, 5000, 330.0)
    assert_equal "1234/5000 completed (24.7%) | ETA 5m 30s", line
  end

  def test_formats_line_without_eta
    line = Bench::ProgressReporter.format_line(0, 5000, nil)
    assert_equal "0/5000 completed (0.0%) | ETA calculating...", line
  end

  def test_formats_line_with_zero_expected_total
    line = Bench::ProgressReporter.format_line(0, 0, nil)
    assert_equal "0/0 completed (0.0%) | ETA calculating...", line
  end
end
