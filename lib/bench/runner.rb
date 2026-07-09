# lib/bench/runner.rb
require "json"
require "fileutils"
require "time"
require "bench/shell"
require "bench/mysql_client"
require "bench/digests"
require "bench/samplers"
require "bench/progress_reporter"
require "bench/stats"
require "bench/result"

module Bench
  class Runner
    RunFailure = Class.new(StandardError)

    def initialize(scenario:, source:, profile:, root:, timeout: 900, allow_dirty: false)
      @scenario = scenario   # Bench::Scenarios::Scenario
      @source = source       # Bench::SourceSpec
      @profile = profile     # Bench::Profile
      @root = root
      @timeout = timeout
      @allow_dirty = allow_dirty
      @mysql = MysqlClient.new
      @digests = Digests.new(client: @mysql)
    end

    def call
      started_at = Time.now
      run_id = "#{started_at.strftime("%Y%m%d-%H%M%S")}-#{@scenario.name}-#{@source.key}"
      result = Result.new(
        run_id: run_id,
        scenario: { name: @scenario.name, params: @scenario.params, expected_total: @scenario.expected_total },
        source: nil, profile: @profile.to_h,
        status: "failed", error: nil,
        timings: { started_at: started_at.utc.iso8601 }, metrics: {}
      )
      logs = result.logs_dir(results_dir: results_dir)
      supervisor_pid = nil
      cpu = depth = nil

      begin
        result.source = prepare_source
        mysql_fresh_start
        db_setup(logs)
        supervisor_pid = start_supervisor(logs)
        wait_for_processes
        @digests.reset
        cpu = CpuSampler.new.start
        depth = DepthSampler.new(client: MysqlClient.new).start

        scenario_started = Time.now
        run_driver(logs)
        wait_for_drain(depth)
        drained_at = Time.now

        cpu_samples = cpu.stop
        depth_samples = depth.stop
        cpu = depth = nil
        digest_rows = @digests.fetch

        result.metrics = build_metrics(cpu_samples, depth_samples, digest_rows, scenario_started, drained_at)
        result.timings = result.timings.merge(
          scenario_started_at: scenario_started.utc.iso8601,
          drained_at: drained_at.utc.iso8601,
          wall_seconds: (drained_at - scenario_started).round(1)
        )
        result.status = "completed"
      rescue StandardError => e
        result.error = "#{e.class}: #{e.message}"
        warn "RUN FAILED: #{result.error}"
      ensure
        begin
          cpu&.stop
          depth&.stop
          stop_supervisor(supervisor_pid) if supervisor_pid
          compose_down
        rescue StandardError => teardown_error
          warn "teardown error (ignored): #{teardown_error.message}"
        end
      end

      path = result.write(results_dir: results_dir)
      puts "#{result.status}: #{path}"
      result
    end

    private

    def results_dir = File.join(@root, "results")
    def harness_dir = File.join(@root, "harness")
    def gemfile_path = File.join(@root, "gemfiles", "#{@source.key}.gemfile")

    def base_env
      {
        "BUNDLE_GEMFILE" => gemfile_path,
        "RAILS_ENV" => "production"
      }.merge(@profile.env)
    end

    def compose_env
      @profile.env.merge("BENCH_MYSQL_PORT" => mysql_port)
    end

    def mysql_port = ENV.fetch("BENCH_MYSQL_PORT", "13306")

    # --- gem source ---

    def prepare_source
      if @source.kind == :path && @source.git_dirty? && !@allow_dirty
        raise RunFailure, "fork working tree is dirty at #{@source.path} — commit, or pass --allow-dirty"
      end
      FileUtils.mkdir_p(File.join(@root, "gemfiles"))
      File.write(gemfile_path, @source.wrapper_gemfile_contents)
      begin
        Shell.capture(Shell.bundle_cmd("check"), env: base_env)
      rescue Shell::Error
        Shell.capture(Shell.bundle_cmd("install"), env: base_env)
      end
      build_source_info
    end

    def build_source_info
      version = Shell.capture(
        Shell.bundle_cmd("exec", *Shell.ruby_cmd("-e", 'require "solid_queue/version"; print SolidQueue::VERSION')),
        env: base_env
      ).strip
      sha = @source.git_sha
      sha = "#{sha}+dirty" if sha && @source.git_dirty?
      { spec: @source.to_s, resolved_version: version, sha: sha, dirty: @source.git_dirty? }
    end

    # --- infrastructure ---

    def mysql_fresh_start
      compose_down
      Shell.capture(%w[docker compose up -d --wait], env: compose_env)
    end

    def compose_down
      Shell.capture(%w[docker compose down -v], env: compose_env)
    end

    def db_setup(logs)
      out = Shell.capture(
        Shell.bundle_cmd("exec", *Shell.ruby_cmd("bin/rails", "runner", "script/db_setup.rb")),
        env: base_env, chdir: harness_dir
      )
      File.write(File.join(logs, "db_setup.log"), out)
    end

    # --- processes ---

    def start_supervisor(logs)
      Shell.spawn_logged(
        Shell.bundle_cmd("exec", *Shell.ruby_cmd("bin/jobs", "start")),
        env: base_env, chdir: harness_dir,
        log_path: File.join(logs, "supervisor.log")
      )
    end

    def stop_supervisor(pid)
      Process.kill("TERM", pid)
      60.times do
        return if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.5
      end
      Process.kill("KILL", pid) rescue nil
      Process.waitpid(pid) rescue nil
    rescue Errno::ESRCH, Errno::ECHILD
      # already gone
    end

    def wait_for_processes
      deadline = Time.now + 120
      expected = @profile.expected_process_count
      loop do
        count = @mysql.scalar("SELECT COUNT(*) FROM solid_queue_processes").to_i
        return if count >= expected
        raise RunFailure, "timed out waiting for #{expected} solid_queue processes (saw #{count})" if Time.now > deadline
        sleep 1
      end
    end

    # --- scenario ---

    def run_driver(logs)
      scenario_file = File.join(results_dir, "scenario-#{@scenario.name}.json")
      File.write(scenario_file, JSON.generate({ scenario: @scenario.name, params: @scenario.params }))
      pid = Shell.spawn_logged(
        Shell.bundle_cmd("exec", *Shell.ruby_cmd("bin/rails", "runner", "script/drive.rb")),
        env: base_env.merge("BENCH_SCENARIO_FILE" => scenario_file),
        chdir: harness_dir, log_path: File.join(logs, "driver.log")
      )
      _, status = Process.waitpid2(pid)
      raise RunFailure, "scenario driver failed (see logs/driver.log)" unless status.success?
    end

    def wait_for_drain(depth_sampler)
      return if @scenario.expected_total.zero?
      reporter = ProgressReporter.new(expected_total: @scenario.expected_total)
      deadline = Time.now + @timeout
      begin
        loop do
          snap = depth_sampler.latest
          if snap && snap["failed"].positive?
            raise RunFailure, "#{snap["failed"]} job(s) failed during the run (see solid_queue_failed_executions)"
          end
          reporter.update(depth_sampler.samples) if snap
          if snap && snap["completed"] >= @scenario.expected_total &&
             snap.values_at("ready", "scheduled", "claimed", "blocked").sum.zero?
            return
          end
          if Time.now > deadline
            done = snap ? snap["completed"] : "?"
            raise RunFailure, "drain timeout after #{@timeout}s (#{done}/#{@scenario.expected_total} completed)"
          end
          sleep 1
        end
      ensure
        reporter.finish(depth_sampler.samples)
      end
    end

    # --- metrics ---

    def build_metrics(cpu_samples, depth_samples, digest_rows, scenario_started, drained_at)
      rows = @mysql.query(<<~SQL.tr("\n", " "))
        SELECT TIMESTAMPDIFF(MICROSECOND, enqueued_at, started_at) / 1000,
               TIMESTAMPDIFF(MICROSECOND, enqueued_at, finished_at) / 1000,
               UNIX_TIMESTAMP(finished_at)
        FROM bench_events
      SQL
      to_start = rows.map { |r| r[0].to_f }
      to_finish = rows.map { |r| r[1].to_f }
      finished_ts = rows.map { |r| r[2].to_f }
      wall = [drained_at - scenario_started, 0.001].max
      cpu_values = cpu_samples.map { |s| s["cpu_pct"] }
      failed = @mysql.scalar("SELECT COUNT(*) FROM solid_queue_failed_executions").to_i

      {
        completed_jobs: rows.length,
        failed_jobs: failed,
        throughput_jobs_per_sec: (rows.length / wall).round(2),
        throughput_series: Stats.per_second(finished_ts),
        latency_ms: {
          enqueue_to_start: Stats.summary(to_start),
          enqueue_to_finish: Stats.summary(to_finish)
        },
        mysql_cpu: {
          avg_pct: cpu_values.empty? ? nil : (cpu_values.sum / cpu_values.length).round(1),
          max_pct: cpu_values.empty? ? nil : cpu_values.max,
          series: cpu_samples
        },
        queue_depth_series: depth_samples,
        top_statements: digest_rows
      }
    end
  end
end
