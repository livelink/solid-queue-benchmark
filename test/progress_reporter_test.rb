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

require "stringio"

class FakeTTY
  attr_reader :writes

  def initialize
    @writes = []
  end

  def tty? = true
  def print(str) = @writes << str
end

class ProgressReporterInstanceTest < Minitest::Test
  def test_update_is_noop_with_empty_samples
    io = StringIO.new
    Bench::ProgressReporter.new(expected_total: 500, io: io).update([])
    assert_equal "", io.string
  end

  def test_non_tty_prints_immediately_then_throttles_by_sample_time
    io = StringIO.new
    reporter = Bench::ProgressReporter.new(expected_total: 500, io: io, plain_interval: 10)

    reporter.update([{ "t" => 0.0, "completed" => 10 }])
    reporter.update([{ "t" => 0.0, "completed" => 10 }, { "t" => 5.0, "completed" => 60 }])
    reporter.update([
      { "t" => 0.0, "completed" => 10 }, { "t" => 5.0, "completed" => 60 },
      { "t" => 11.0, "completed" => 120 }
    ])

    lines = io.string.lines
    assert_equal 2, lines.length
    assert_includes lines[0], "10/500 completed"
    assert_includes lines[1], "120/500 completed"
  end

  def test_tty_redraws_in_place_on_every_update
    io = FakeTTY.new
    reporter = Bench::ProgressReporter.new(expected_total: 500, io: io)

    reporter.update([{ "t" => 0.0, "completed" => 10 }])
    reporter.update([{ "t" => 0.1, "completed" => 12 }])

    assert_equal 2, io.writes.length
    assert_match(/\A\r10\/500 completed.*\e\[K\z/, io.writes[0])
    assert_match(/\A\r12\/500 completed.*\e\[K\z/, io.writes[1])
  end

  def test_finish_prints_newline_on_tty_only
    tty_io = FakeTTY.new
    Bench::ProgressReporter.new(expected_total: 500, io: tty_io).finish
    assert_equal ["\n"], tty_io.writes

    plain_io = StringIO.new
    Bench::ProgressReporter.new(expected_total: 500, io: plain_io).finish
    assert_equal "", plain_io.string
  end

  def test_finish_forces_an_unthrottled_final_line_on_non_tty
    io = StringIO.new
    reporter = Bench::ProgressReporter.new(expected_total: 500, io: io, plain_interval: 10)

    reporter.update([{ "t" => 0.0, "completed" => 10 }])
    reporter.finish([{ "t" => 0.0, "completed" => 10 }, { "t" => 1.0, "completed" => 500 }])

    lines = io.string.lines
    assert_equal 2, lines.length
    assert_includes lines[0], "10/500 completed"
    assert_includes lines[1], "500/500 completed"
  end

  def test_finish_with_no_samples_is_a_noop_on_non_tty
    io = StringIO.new
    Bench::ProgressReporter.new(expected_total: 500, io: io).finish
    assert_equal "", io.string
  end
end
