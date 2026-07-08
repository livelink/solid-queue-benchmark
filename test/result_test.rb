# test/result_test.rb
require "test_helper"
require "bench/result"
require "tmpdir"

class ResultTest < Minitest::Test
  def sample_attrs
    {
      run_id: "20260708-140000-baseline-upstream-latest",
      scenario: { name: "baseline", params: { "jobs" => 100 }, expected_total: 100 },
      source: { spec: "upstream", resolved_version: "1.2.4", sha: nil, dirty: false },
      profile: { name: "smoke", workers: 2 },
      status: "completed",
      error: nil,
      timings: { started_at: "2026-07-08T14:00:00Z", wall_seconds: 42.5 },
      metrics: { throughput_jobs_per_sec: 88.1 }
    }
  end

  def test_write_and_load_roundtrip
    Dir.mktmpdir do |dir|
      result = Bench::Result.new(**sample_attrs)
      path = result.write(results_dir: dir)
      assert_equal File.join(dir, "20260708-140000-baseline-upstream-latest", "result.json"), path
      loaded = Bench::Result.load(path)
      assert_equal "completed", loaded.status
      assert_equal "baseline", loaded.scenario["name"]
      assert_equal 88.1, loaded.metrics["throughput_jobs_per_sec"]
    end
  end

  def test_logs_dir
    Dir.mktmpdir do |dir|
      result = Bench::Result.new(**sample_attrs)
      logs = result.logs_dir(results_dir: dir)
      assert File.directory?(logs)
      assert_equal File.join(dir, result.run_id, "logs"), logs
    end
  end
end
