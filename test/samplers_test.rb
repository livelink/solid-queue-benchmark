# test/samplers_test.rb
require "test_helper"
require "bench/samplers"

class CpuSamplerParseTest < Minitest::Test
  # docker stats --format '{{json .}}' emits ANSI cursor/clear codes around
  # (and, critically, *after*) the JSON object on each line.
  RAW_LINE = "\e[H{\"BlockIO\":\"36.6MB / 531MB\",\"CPUPerc\":\"12.34%\",\"Container\":\"sq-bench-mysql\"}\e[K\n"

  def test_parses_cpu_pct_from_line_with_trailing_ansi_codes
    assert_in_delta 12.34, Bench::CpuSampler.parse_cpu_pct(RAW_LINE), 0.001
  end

  def test_returns_nil_for_ansi_only_line
    assert_nil Bench::CpuSampler.parse_cpu_pct("\e[K\n")
  end

  def test_returns_nil_for_unparseable_line
    assert_nil Bench::CpuSampler.parse_cpu_pct("\e[J\e[H\n")
  end
end
