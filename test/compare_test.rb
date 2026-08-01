# test/compare_test.rb
require "test_helper"
require "bench/compare"
require "bench/result"

class CompareTest < Minitest::Test
  def result(overrides = {})
    base = {
      run_id: "20260708-a",
      database: "mysql",
      status: "completed",
      error: nil,
      scenario: { "name" => "baseline", "params" => { "jobs" => 100 }, "expected_total" => 100 },
      source: { "spec" => "upstream", "resolved_version" => "1.2.4", "sha" => nil, "dirty" => false },
      profile: { "name" => "smoke", "workers" => 2, "threads" => 2, "db_cpus" => 1.0 },
      timings: { "wall_seconds" => 10.0 },
      metrics: {
        "completed_jobs" => 100,
        "throughput_jobs_per_sec" => 50.0,
        "latency_ms" => {
          "enqueue_to_start" => { "p50" => 20.0, "p95" => 80.0, "p99" => 120.0 },
          "enqueue_to_finish" => { "p50" => 25.0, "p95" => 90.0, "p99" => 130.0 }
        },
        "db_cpu" => { "avg_pct" => 40.0, "max_pct" => 70.0, "series" => [{ "t" => 1.0, "cpu_pct" => 40.0 }] },
        "queue_depth_series" => [{ "t" => 1.0, "ready" => 5, "scheduled" => 0, "claimed" => 2, "blocked" => 0, "completed" => 10 }],
        "top_statements" => [{ "digest_text" => "SELECT ...", "count" => 100, "total_ms" => 50.0, "rows_examined" => 200 }]
      }
    }
    Bench::Result.new(**base.merge(overrides))
  end

  def test_refuses_mismatched_profiles_without_force
    b = result(profile: { "name" => "default", "workers" => 10, "threads" => 2, "db_cpus" => 1.0 })
    assert_raises(Bench::Compare::ProfileMismatch) do
      Bench::Compare.render_markdown(result, b, force: false)
    end
  end

  def test_force_allows_mismatched_profiles
    b = result(profile: { "name" => "default", "workers" => 10, "threads" => 2, "db_cpus" => 1.0 })
    md = Bench::Compare.render_markdown(result, b, force: true)
    assert_includes md, "PROFILES DIFFER"
  end

  def test_markdown_contains_deltas
    b = result(run_id: "20260708-b", metrics: result.metrics.merge("throughput_jobs_per_sec" => 75.0))
    md = Bench::Compare.render_markdown(result, b, force: false)
    assert_includes md, "Throughput (jobs/sec)"
    assert_includes md, "+50.0%"
    assert_includes md, "1.2.4"
  end

  def test_markdown_shows_database_row_without_mismatch_guard
    b = result(run_id: "20260708-b", database: "postgres")
    md = Bench::Compare.render_markdown(result, b, force: false)
    assert_includes md, "| Database | mysql | postgres |"
  end

  def test_html_contains_svg_charts
    html = Bench::Compare.render_html(result, result(run_id: "20260708-b"), force: false)
    assert_includes html, "<svg"
    assert_includes html, "DB CPU"
  end
end
