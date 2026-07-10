# Postgres Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Postgres as a second, selectable database engine for the benchmark tool, so a run can target either MySQL or Postgres and results from both can be compared like-for-like via `bin/bench compare`.

**Architecture:** A new `Bench::Engines` registry centralizes the handful of facts that differ per engine (client class, container name, compose service, port env var, digest SQL). `Bench::PostgresClient` mirrors the existing `Bench::MysqlClient` exactly. `Runner`, `CLI`, `Digests`, `Profile`, `Result`, and `Compare` are updated to be engine-neutral, consulting the registry instead of hardcoding MySQL. `docker-compose.yml` gains a `postgres` service; only the selected engine's container is started per run.

**Tech Stack:** Ruby (stdlib only for `lib/bench/*`), Minitest, Docker Compose, MySQL 8.0 (`trilogy` adapter), Postgres 16 (`pg` adapter + `pg_stat_statements`), Rails/ActiveRecord harness.

**Spec:** `docs/jeongri/specs/2026-07-10-postgres-support-design.md`

---

## Before you start

All commands below assume the repo root as your working directory and use the project's pinned Ruby via mise. Confirm this works first:

```bash
mise exec -- ruby -v
```

Expected: prints a Ruby 3.3.x version line. If `mise` reports the directory isn't trusted, run `mise trust` once first.

Run the full existing test suite once, before any changes, to establish a clean baseline:

```bash
mise exec -- ruby -Ilib -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'
```

Expected: all tests pass, `0 failures, 0 errors`.

---

### Task 1: `Bench::PostgresClient`

**Files:**
- Create: `lib/bench/postgres_client.rb`
- Test: `test/postgres_client_test.rb`

`MysqlClient` (`lib/bench/mysql_client.rb`) shells out to `docker compose exec -T mysql mysql ...` and splits TSV output. `PostgresClient` does the same thing via `psql`, with an identical `#query`/`#scalar` interface.

- [ ] **Step 1: Write the failing test**

Create `test/postgres_client_test.rb`:

```ruby
# test/postgres_client_test.rb
require "test_helper"
require "bench/postgres_client"

class PostgresClientTest < Minitest::Test
  def test_query_parses_tsv_rows
    fake = lambda do |cmd, env: {}|
      assert_equal %w[docker compose exec -T postgres psql -U bench -d bench -tA -F] + ["\t", "-c"], cmd[0..-2]
      assert_equal "SELECT 1, 'a'", cmd.last
      "1\ta\n2\tb\n"
    end
    client = Bench::PostgresClient.new(runner: fake)
    assert_equal [["1", "a"], ["2", "b"]], client.query("SELECT 1, 'a'")
  end

  def test_scalar
    client = Bench::PostgresClient.new(runner: ->(_cmd, env: {}) { "42\n" })
    assert_equal "42", client.scalar("SELECT COUNT(*) FROM t")
  end

  def test_scalar_nil_on_empty
    client = Bench::PostgresClient.new(runner: ->(_cmd, env: {}) { "" })
    assert_nil client.scalar("SELECT 1 WHERE FALSE")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/postgres_client_test.rb`
Expected: `LoadError: cannot load such file -- bench/postgres_client`

- [ ] **Step 3: Write the implementation**

Create `lib/bench/postgres_client.rb`:

```ruby
# lib/bench/postgres_client.rb
require "bench/shell"

module Bench
  class PostgresClient
    BASE_CMD = (%w[docker compose exec -T postgres psql -U bench -d bench -tA -F] + ["\t", "-c"]).freeze

    def initialize(runner: Shell.method(:capture))
      @runner = runner
    end

    def query(sql)
      out = @runner.call(BASE_CMD + [sql], env: {})
      out.split("\n").map { |line| line.split("\t") }
    end

    def scalar(sql)
      query(sql).dig(0, 0)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/postgres_client_test.rb`
Expected: `3 runs, 3 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/postgres_client.rb test/postgres_client_test.rb
git commit -m "feat: add PostgresClient mirroring MysqlClient"
```

---

### Task 2: `Bench::Engines` registry

**Files:**
- Create: `lib/bench/engines.rb`
- Test: `test/engines_test.rb`

This is the single source of truth for per-engine facts, consulted by `Runner`, `CLI`, and (indirectly, via values it hands to `Digests`) the digest metric.

- [ ] **Step 1: Write the failing test**

Create `test/engines_test.rb`:

```ruby
# test/engines_test.rb
require "test_helper"
require "bench/engines"

class EnginesTest < Minitest::Test
  def test_names
    assert_equal %w[mysql postgres], Bench::Engines.names
  end

  def test_mysql_entry
    engine = Bench::Engines.fetch("mysql")
    assert_equal Bench::MysqlClient, engine.client_class
    assert_equal "sq-bench-mysql", engine.container
    assert_equal "mysql", engine.service
    assert_equal "BENCH_MYSQL_PORT", engine.port_env
    assert_equal 13306, engine.default_port
    assert_includes engine.digest_fetch_sql, "performance_schema"
    assert_includes engine.digest_reset_sql, "TRUNCATE"
  end

  def test_postgres_entry
    engine = Bench::Engines.fetch("postgres")
    assert_equal Bench::PostgresClient, engine.client_class
    assert_equal "sq-bench-postgres", engine.container
    assert_equal "postgres", engine.service
    assert_equal "BENCH_POSTGRES_PORT", engine.port_env
    assert_equal 15432, engine.default_port
    assert_includes engine.digest_fetch_sql, "pg_stat_statements"
    assert_includes engine.digest_reset_sql, "pg_stat_statements_reset"
  end

  def test_fetch_unknown_raises
    err = assert_raises(ArgumentError) { Bench::Engines.fetch("bogus") }
    assert_includes err.message, "bogus"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/engines_test.rb`
Expected: `LoadError: cannot load such file -- bench/engines`

- [ ] **Step 3: Write the implementation**

Create `lib/bench/engines.rb`:

```ruby
# lib/bench/engines.rb
require "bench/mysql_client"
require "bench/postgres_client"

module Bench
  module Engines
    Engine = Struct.new(
      :name, :client_class, :container, :service, :port_env, :default_port,
      :digest_reset_sql, :digest_fetch_sql,
      keyword_init: true
    )

    MYSQL_DIGEST_FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED
      FROM performance_schema.events_statements_summary_by_digest
      WHERE SCHEMA_NAME = 'bench'
      ORDER BY SUM_TIMER_WAIT DESC
      LIMIT 20
    SQL

    POSTGRES_DIGEST_FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT query, calls, ROUND(total_exec_time, 1), rows
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'bench')
      ORDER BY total_exec_time DESC
      LIMIT 20
    SQL

    REGISTRY = {
      "mysql" => Engine.new(
        name: "mysql",
        client_class: MysqlClient,
        container: "sq-bench-mysql",
        service: "mysql",
        port_env: "BENCH_MYSQL_PORT",
        default_port: 13306,
        digest_reset_sql: "TRUNCATE performance_schema.events_statements_summary_by_digest",
        digest_fetch_sql: MYSQL_DIGEST_FETCH_SQL
      ),
      "postgres" => Engine.new(
        name: "postgres",
        client_class: PostgresClient,
        container: "sq-bench-postgres",
        service: "postgres",
        port_env: "BENCH_POSTGRES_PORT",
        default_port: 15432,
        digest_reset_sql: "SELECT pg_stat_statements_reset()",
        digest_fetch_sql: POSTGRES_DIGEST_FETCH_SQL
      )
    }.freeze

    def self.fetch(name)
      REGISTRY.fetch(name) do
        raise ArgumentError, "unknown database #{name.inspect} (available: #{names.join(", ")})"
      end
    end

    def self.names = REGISTRY.keys
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/engines_test.rb`
Expected: `4 runs, 11 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/engines.rb test/engines_test.rb
git commit -m "feat: add Engines registry for per-engine facts"
```

---

### Task 3: Rename `Profile`'s MySQL-specific attributes to engine-neutral names

**Files:**
- Modify: `lib/bench/profile.rb`
- Modify: `profiles/default.yml`
- Modify: `profiles/smoke.yml`
- Test: `test/profile_test.rb`

`mysql_cpus`/`mysql_memory` become `db_cpus`/`db_memory` everywhere (attribute names, env var names, YAML key), since a profile now applies to whichever engine a run selects.

- [ ] **Step 1: Update the test to expect the new names**

Replace `test/profile_test.rb` in full:

```ruby
# test/profile_test.rb
require "test_helper"
require "bench/profile"

class ProfileTest < Minitest::Test
  def test_loads_default_profile_by_name
    p = Bench::Profile.load("default")
    assert_equal 1.0, p.db_cpus
    assert_equal "1g", p.db_memory
    assert_equal 10, p.workers
    assert_equal 2, p.threads
    assert_equal 0.1, p.polling_interval
    assert_equal 1, p.dispatchers
  end

  def test_cli_overrides_win
    p = Bench::Profile.load("default", workers: 50, db_cpus: 2.0)
    assert_equal 50, p.workers
    assert_equal 2.0, p.db_cpus
    assert_equal 2, p.threads # untouched
  end

  def test_env_map
    p = Bench::Profile.load("smoke")
    assert_equal(
      {
        "BENCH_DB_CPUS" => "1.0",
        "BENCH_DB_MEMORY" => "1g",
        "BENCH_WORKER_PROCESSES" => "2",
        "BENCH_WORKER_THREADS" => "2",
        "BENCH_POLLING_INTERVAL" => "0.1"
      },
      p.env
    )
  end

  def test_loads_profile_by_path
    p = Bench::Profile.load("profiles/smoke.yml")
    assert_equal 2, p.workers
    assert_equal "smoke", p.name
  end

  def test_expected_process_count
    p = Bench::Profile.load("default")
    assert_equal 12, p.expected_process_count # 1 supervisor + 10 workers + 1 dispatcher
  end

  def test_to_h_roundtrips_for_result_json
    p = Bench::Profile.load("default")
    h = p.to_h
    assert_equal "default", h[:name]
    assert_equal 10, h[:workers]
    assert_equal 1, h[:dispatchers]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/profile_test.rb`
Expected: `NoMethodError: undefined method 'db_cpus' for an instance of Bench::Profile`

- [ ] **Step 3: Update `Profile` and the profile YAML files**

Replace `lib/bench/profile.rb` in full:

```ruby
# lib/bench/profile.rb
require "yaml"

module Bench
  class Profile
    ATTRS = %i[name db_cpus db_memory workers threads polling_interval dispatchers].freeze
    attr_reader(*ATTRS)

    # name_or_path: a bare profile name resolved under profiles/, or a path to a yml.
    # overrides: {workers:, threads:, db_cpus:, db_memory:} from CLI flags.
    def self.load(name_or_path, overrides = {})
      path = if name_or_path.include?("/") || name_or_path.end_with?(".yml")
        File.expand_path(name_or_path)
      else
        File.expand_path("../../profiles/#{name_or_path}.yml", __dir__)
      end
      raw = YAML.safe_load_file(path) || {}
      new(
        name: File.basename(path, ".yml"),
        db_cpus: (overrides[:db_cpus] || raw.dig("db", "cpus") || 1.0).to_f,
        db_memory: (overrides[:db_memory] || raw.dig("db", "memory") || "1g").to_s,
        workers: (overrides[:workers] || raw.dig("workers", "count") || 10).to_i,
        threads: (overrides[:threads] || raw.dig("workers", "threads") || 2).to_i,
        polling_interval: (raw.dig("workers", "polling_interval") || 0.1).to_f,
        dispatchers: (raw.dig("dispatcher", "count") || 1).to_i
      )
    end

    def initialize(name:, db_cpus:, db_memory:, workers:, threads:, polling_interval:, dispatchers:)
      @name = name
      @db_cpus = db_cpus
      @db_memory = db_memory
      @workers = workers
      @threads = threads
      @polling_interval = polling_interval
      @dispatchers = dispatchers
    end

    def env
      {
        "BENCH_DB_CPUS" => db_cpus.to_s,
        "BENCH_DB_MEMORY" => db_memory,
        "BENCH_WORKER_PROCESSES" => workers.to_s,
        "BENCH_WORKER_THREADS" => threads.to_s,
        "BENCH_POLLING_INTERVAL" => polling_interval.to_s
      }
    end

    # Total solid_queue processes expected to register: supervisor + workers + dispatchers.
    def expected_process_count
      1 + workers + dispatchers
    end

    def to_h
      ATTRS.to_h { |a| [a, public_send(a)] }
    end
  end
end
```

Replace `profiles/default.yml` in full:

```yaml
# Baseline profile: database deliberately small so contention shows at light load,
# preserving the production pressure ratio (many pollers per DB core).
db:
  cpus: 1.0
  memory: 1g
workers:
  count: 10
  threads: 2
  polling_interval: 0.1
dispatcher:
  count: 1
```

Replace `profiles/smoke.yml` in full:

```yaml
db:
  cpus: 1.0
  memory: 1g
workers:
  count: 2
  threads: 2
  polling_interval: 0.1
dispatcher:
  count: 1
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/profile_test.rb`
Expected: `6 runs, 11 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/profile.rb profiles/default.yml profiles/smoke.yml test/profile_test.rb
git commit -m "refactor: rename Profile's mysql_cpus/mysql_memory to db_cpus/db_memory"
```

---

### Task 4: Generalize `Digests` to accept engine-specific SQL

**Files:**
- Modify: `lib/bench/digests.rb`
- Test: `test/digests_test.rb`

`Digests` currently hardcodes MySQL's `TRUNCATE performance_schema...` and a `FETCH_SQL` constant. Both become constructor arguments, supplied by the caller from `Engines`.

- [ ] **Step 1: Update the test to expect SQL injected via the constructor**

Replace `test/digests_test.rb` in full:

```ruby
# test/digests_test.rb
require "test_helper"
require "bench/digests"

class DigestsTest < Minitest::Test
  FakeClient = Struct.new(:rows) do
    def query(sql) = rows
  end

  def test_fetch_maps_mysql_style_rows
    rows = [["SELECT * FROM `solid_queue_ready_executions` ...", "1500", "2345.6", "150000"]]
    digests = Bench::Digests.new(
      client: FakeClient.new(rows),
      reset_sql: "TRUNCATE performance_schema.events_statements_summary_by_digest",
      fetch_sql: "SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED " \
                 "FROM performance_schema.events_statements_summary_by_digest"
    )
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM `solid_queue_ready_executions` ...", result[0][:digest_text]
    assert_equal 1500, result[0][:count]
    assert_equal 2345.6, result[0][:total_ms]
    assert_equal 150_000, result[0][:rows_examined]
  end

  def test_fetch_maps_postgres_style_rows
    rows = [["SELECT * FROM pg_stat_statements ...", "42", "10.5", "9000"]]
    digests = Bench::Digests.new(
      client: FakeClient.new(rows),
      reset_sql: "SELECT pg_stat_statements_reset()",
      fetch_sql: "SELECT query, calls, ROUND(total_exec_time, 1), rows FROM pg_stat_statements"
    )
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM pg_stat_statements ...", result[0][:digest_text]
    assert_equal 42, result[0][:count]
    assert_equal 10.5, result[0][:total_ms]
    assert_equal 9000, result[0][:rows_examined]
  end

  def test_reset_issues_the_given_sql
    recorder = Struct.new(:queries) do
      def query(sql)
        queries << sql
        []
      end
    end.new([])
    digests = Bench::Digests.new(
      client: recorder,
      reset_sql: "SELECT pg_stat_statements_reset()",
      fetch_sql: "SELECT 1"
    )
    digests.reset
    assert_equal ["SELECT pg_stat_statements_reset()"], recorder.queries
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/digests_test.rb`
Expected: `ArgumentError: missing keywords: :reset_sql, :fetch_sql`

- [ ] **Step 3: Update the implementation**

Replace `lib/bench/digests.rb` in full:

```ruby
# lib/bench/digests.rb
module Bench
  class Digests
    def initialize(client:, reset_sql:, fetch_sql:)
      @client = client
      @reset_sql = reset_sql
      @fetch_sql = fetch_sql
    end

    # Zero the digest table/stats. Called after workers register, before enqueue starts,
    # so captured stats cover steady-state benchmark activity only.
    def reset
      @client.query(@reset_sql)
    end

    def fetch
      @client.query(@fetch_sql).map do |text, count, total_ms, rows_examined|
        { digest_text: text, count: count.to_i, total_ms: total_ms.to_f, rows_examined: rows_examined.to_i }
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/digests_test.rb`
Expected: `3 runs, 9 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/digests.rb test/digests_test.rb
git commit -m "refactor: inject Digests SQL via constructor instead of hardcoding MySQL"
```

---

### Task 5: Add a `database` field to `Result`

**Files:**
- Modify: `lib/bench/result.rb`
- Modify: `test/result_test.rb`

- [ ] **Step 1: Update the test to expect the new field**

In `test/result_test.rb`, update `sample_attrs` and `test_write_and_load_roundtrip`:

```ruby
  def sample_attrs
    {
      run_id: "20260708-140000-baseline-upstream-latest",
      database: "postgres",
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
      assert_equal "postgres", loaded.database
      assert_equal "baseline", loaded.scenario["name"]
      assert_equal 88.1, loaded.metrics["throughput_jobs_per_sec"]
    end
  end
```

Leave `test_write_rejects_unsafe_run_id` and `test_logs_dir` as they are — they don't assert on `database` and `Result.new(**sample_attrs, run_id: ...)` already works with the extra field.

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/result_test.rb`
Expected: `NoMethodError: undefined method 'database' for an instance of Bench::Result`

- [ ] **Step 3: Add the field**

In `lib/bench/result.rb`, change:

```ruby
    FIELDS = %i[run_id scenario source profile status error timings metrics].freeze
```

to:

```ruby
    FIELDS = %i[run_id database scenario source profile status error timings metrics].freeze
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/result_test.rb`
Expected: `3 runs, 8 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/result.rb test/result_test.rb
git commit -m "feat: add database field to Result"
```

---

### Task 6: Wire `Runner` to the selected engine

**Files:**
- Modify: `lib/bench/runner.rb`

`Runner` has no dedicated unit tests today (it's the integration orchestrator, exercised via `mise run smoke`) — this task's verification is a syntax check plus a full regression run of the existing suite, followed by the end-to-end manual smoke test in Task 14.

- [ ] **Step 1: Replace the implementation**

Replace `lib/bench/runner.rb` in full:

```ruby
# lib/bench/runner.rb
require "json"
require "fileutils"
require "time"
require "bench/shell"
require "bench/engines"
require "bench/digests"
require "bench/samplers"
require "bench/progress_reporter"
require "bench/stats"
require "bench/result"

module Bench
  class Runner
    RunFailure = Class.new(StandardError)

    def initialize(scenario:, source:, profile:, root:, database: "mysql", timeout: 900, allow_dirty: false)
      @scenario = scenario   # Bench::Scenarios::Scenario
      @source = source       # Bench::SourceSpec
      @profile = profile     # Bench::Profile
      @root = root
      @database = database
      @engine = Engines.fetch(database)
      @timeout = timeout
      @allow_dirty = allow_dirty
      @db = @engine.client_class.new
      @digests = Digests.new(client: @db, reset_sql: @engine.digest_reset_sql, fetch_sql: @engine.digest_fetch_sql)
    end

    def call
      started_at = Time.now
      run_id = "#{started_at.strftime("%Y%m%d-%H%M%S")}-#{@scenario.name}-#{@database}-#{@source.key}"
      result = Result.new(
        run_id: run_id,
        database: @database,
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
        db_fresh_start
        db_setup(logs)
        supervisor_pid = start_supervisor(logs)
        wait_for_processes
        @digests.reset
        cpu = CpuSampler.new(container: @engine.container).start
        depth = DepthSampler.new(client: @engine.client_class.new).start

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
        "RAILS_ENV" => "production",
        "BENCH_DATABASE" => @database
      }.merge(@profile.env)
    end

    def compose_env
      @profile.env.merge(@engine.port_env => db_port)
    end

    def db_port = ENV.fetch(@engine.port_env, @engine.default_port.to_s)

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

    def db_fresh_start
      compose_down
      Shell.capture(%w[docker compose up -d --wait] + [@engine.service], env: compose_env)
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
        count = @db.scalar("SELECT COUNT(*) FROM solid_queue_processes").to_i
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
      rows = @db.query("SELECT enqueued_at, started_at, finished_at FROM bench_events")
      to_start = rows.map { |enqueued_at, started_at, _finished_at| (Time.parse(started_at) - Time.parse(enqueued_at)) * 1000 }
      to_finish = rows.map { |enqueued_at, _started_at, finished_at| (Time.parse(finished_at) - Time.parse(enqueued_at)) * 1000 }
      finished_ts = rows.map { |_enqueued_at, _started_at, finished_at| Time.parse(finished_at).to_f }
      wall = [drained_at - scenario_started, 0.001].max
      cpu_values = cpu_samples.map { |s| s["cpu_pct"] }
      failed = @db.scalar("SELECT COUNT(*) FROM solid_queue_failed_executions").to_i

      {
        completed_jobs: rows.length,
        failed_jobs: failed,
        throughput_jobs_per_sec: (rows.length / wall).round(2),
        throughput_series: Stats.per_second(finished_ts),
        latency_ms: {
          enqueue_to_start: Stats.summary(to_start),
          enqueue_to_finish: Stats.summary(to_finish)
        },
        db_cpu: {
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
```

Note what changed from the previous version: `@mysql` → `@db` (via `@engine.client_class.new`), `mysql_fresh_start`/`mysql_port` → `db_fresh_start`/`db_port`, `CpuSampler`/`DepthSampler` now take engine-specific container/client, `base_env` carries `BENCH_DATABASE` for the harness's `database.yml`, `run_id` includes `@database`, `Result.new` gets a `database:` value, and `build_metrics`'s latency query fetches raw timestamps and diffs them with `Time.parse` instead of MySQL-only `TIMESTAMPDIFF`/`UNIX_TIMESTAMP` SQL — this is the one deliberately new pattern in this task, needed because no single SQL expression works unmodified against both `trilogy` and `pg` output. The metrics hash key `mysql_cpu` is renamed to `db_cpu`.

- [ ] **Step 2: Syntax-check the file**

Run: `mise exec -- ruby -c lib/bench/runner.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Run the full existing test suite to confirm nothing else broke**

Run: `mise exec -- ruby -Ilib -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'`
Expected: all tests pass (Runner has no direct tests, so this just confirms no other file broke from the `Engines`/`Digests`/`Result` changes it depends on).

- [ ] **Step 4: Commit**

```bash
git add lib/bench/runner.rb
git commit -m "feat: wire Runner to the selected database engine"
```

---

### Task 7: Add `--database` to the CLI and rename resource-limit flags

**Files:**
- Modify: `lib/bench/cli.rb`
- Test: `test/cli_test.rb`

- [ ] **Step 1: Update the test to expect the new flag and renamed overrides**

Replace `test/cli_test.rb` in full:

```ruby
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
    assert_equal "mysql", opts[:database]
  end

  def test_parse_run_options_accepts_postgres_database
    opts = Bench::CLI.parse_run_options(%w[baseline --source upstream --database postgres])
    assert_equal "postgres", opts[:database]
  end

  def test_parse_run_options_accepts_db_resource_overrides
    opts = Bench::CLI.parse_run_options(%w[baseline --source upstream --db-cpus 2 --db-memory 2g])
    assert_equal 2.0, opts[:overrides][:db_cpus]
    assert_equal "2g", opts[:overrides][:db_memory]
  end

  def test_rejects_unknown_database
    err = assert_raises(ArgumentError) do
      Bench::CLI.parse_run_options(%w[baseline --source upstream --database oracle])
    end
    assert_includes err.message, "oracle"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/cli_test.rb`
Expected: `Minitest::UnexpectedError` / `NoMethodError` from `--db-cpus`/`--db-memory` being unrecognized options, and `assert_equal "mysql", opts[:database]` failing with `opts[:database]` being `nil`.

- [ ] **Step 3: Update the implementation**

In `lib/bench/cli.rb`, add the require and update `usage`, `parse_run_options`, `run`, `list`, and `setup`:

```ruby
# lib/bench/cli.rb
require "json"
require "optparse"
require "bench/source_spec"
require "bench/profile"
require "bench/scenarios"
require "bench/engines"

module Bench
  module CLI
    ROOT = File.expand_path("../..", __dir__)

    module_function

    def start(argv)
      case argv.first
      when "run" then run(argv.drop(1))
      when "list" then list
      when "setup" then setup
      when "compare" then compare(argv.drop(1))
      else
        puts usage
        exit(argv.empty? ? 0 : 1)
      end
    rescue ArgumentError => e
      warn "error: #{e.message}"
      exit 1
    end

    def usage
      <<~USAGE
        Usage: bin/bench <command>
          run <scenario> --source <src> [options]   Run a benchmark
          compare <result.json> <result.json>       Compare two runs
          list                                      List past runs
          setup                                     Bundle default source + pull database images

        Scenarios: #{Scenarios.names.join(", ")}
        Sources:   upstream | upstream@1.2.4 | path:/dir/of/solid_queue
        Databases: #{Engines.names.join(" | ")} (default: mysql)
      USAGE
    end

    def parse_run_options(argv)
      opts = {
        profile: "default",
        params: {},
        overrides: {},
        timeout: 900,
        repeat: 1,
        allow_dirty: false,
        database: "mysql"
      }
      parser = OptionParser.new do |o|
        o.on("--source SRC") { |v| opts[:source] = v }
        o.on("--profile NAME") { |v| opts[:profile] = v }
        o.on("--database ENGINE") { |v| opts[:database] = v }
        o.on("--set KEY=VAL", "Scenario param override (repeatable)") do |v|
          key, value = v.split("=", 2)
          raise ArgumentError, "--set must be KEY=VAL" if key.nil? || key.empty? || value.nil?
          opts[:params][key] = value
        end
        o.on("--workers N", Integer) { |v| opts[:overrides][:workers] = v }
        o.on("--threads N", Integer) { |v| opts[:overrides][:threads] = v }
        o.on("--db-cpus N", Float) { |v| opts[:overrides][:db_cpus] = v }
        o.on("--db-memory SIZE") { |v| opts[:overrides][:db_memory] = v }
        o.on("--timeout SECONDS", Integer) { |v| opts[:timeout] = v }
        o.on("--repeat N", Integer) { |v| opts[:repeat] = v }
        o.on("--allow-dirty") { opts[:allow_dirty] = true }
      end
      positional = parser.parse(argv)
      opts[:scenario] = positional.first
      raise ArgumentError, "scenario required (#{Scenarios.names.join(", ")})" unless opts[:scenario]
      raise ArgumentError, "--source required" unless opts[:source]
      raise ArgumentError, "--repeat must be >= 1" if opts[:repeat] < 1
      unless Engines.names.include?(opts[:database])
        raise ArgumentError, "--database must be one of #{Engines.names.join(", ")} (got #{opts[:database].inspect})"
      end
      opts
    end

    def run(argv)
      require "bench/runner"
      opts = parse_run_options(argv)
      scenario = Scenarios.build(opts[:scenario], opts[:params])
      source = SourceSpec.parse(opts[:source])
      profile = Profile.load(opts[:profile], opts[:overrides])

      results = opts[:repeat].times.map do |i|
        puts "== run #{i + 1}/#{opts[:repeat]}: #{scenario.name} | #{source} | #{opts[:database]} | profile #{profile.name}" \
             " (#{profile.workers}w x #{profile.threads}t, #{opts[:database]} #{profile.db_cpus}cpu)"
        Runner.new(
          scenario: scenario,
          source: source,
          profile: profile,
          root: ROOT,
          database: opts[:database],
          timeout: opts[:timeout],
          allow_dirty: opts[:allow_dirty]
        ).call
      end

      summarize_repeats(results) if opts[:repeat] > 1
      exit(results.all? { |r| r.status == "completed" } ? 0 : 1)
    end

    def summarize_repeats(results)
      completed = results.select { |r| r.status == "completed" }
      throughputs = completed.map { |r| r.metrics[:throughput_jobs_per_sec] }.compact.sort
      median = throughputs.empty? ? "-" : throughputs[throughputs.length / 2]
      puts "== #{completed.length}/#{results.length} completed; median throughput: #{median} jobs/sec"
    end

    def list
      paths = Dir.glob(File.join(ROOT, "results", "*", "result.json")).sort
      return puts "no results found" if paths.empty?

      paths.each do |path|
        data = JSON.parse(File.read(path))
        metrics = data["metrics"] || {}
        puts format(
          "%-60s %-9s %10s jobs/sec  cpu avg %s%%",
          data["run_id"],
          data["status"],
          metrics["throughput_jobs_per_sec"] || "-",
          metrics.dig("db_cpu", "avg_pct") || "-"
        )
      end
    end

    def setup
      require "fileutils"
      require "bench/shell"
      source = SourceSpec.parse("upstream")
      FileUtils.mkdir_p(File.join(ROOT, "gemfiles"))
      gemfile = File.join(ROOT, "gemfiles", "#{source.key}.gemfile")
      File.write(gemfile, source.wrapper_gemfile_contents)
      Shell.capture(Shell.bundle_cmd("install"), env: { "BUNDLE_GEMFILE" => gemfile })
      Shell.capture(%w[docker compose pull mysql postgres])
      puts "setup: ok"
    end

    def compare(argv)
      require "bench/compare"
      Compare.run(argv, root: ROOT)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/cli_test.rb`
Expected: `7 runs, 15 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/cli.rb test/cli_test.rb
git commit -m "feat: add --database flag and rename --mysql-cpus/--mysql-memory to --db-cpus/--db-memory"
```

---

### Task 8: Make `Compare` engine-neutral and show which engine each run used

**Files:**
- Modify: `lib/bench/compare.rb`
- Test: `test/compare_test.rb`

- [ ] **Step 1: Update the test**

Replace `test/compare_test.rb` in full:

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- ruby -Ilib -Itest test/compare_test.rb`
Expected: `test_markdown_shows_database_row_without_mismatch_guard` fails (`"| Database | mysql | postgres |"` not found), and `test_html_contains_svg_charts` fails (`"DB CPU"` not found — still says `"MySQL CPU"`).

- [ ] **Step 3: Update the implementation**

Replace `lib/bench/compare.rb` in full:

```ruby
# lib/bench/compare.rb
require "cgi"
require "fileutils"
require "bench/result"
require "bench/svg_chart"

module Bench
  module Compare
    ProfileMismatch = Class.new(StandardError)

    METRIC_ROWS = [
      ["Throughput (jobs/sec)", ->(m) { m["throughput_jobs_per_sec"] }, :higher_better],
      ["Enqueue to start p50 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p50") }, :lower_better],
      ["Enqueue to start p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p95") }, :lower_better],
      ["Enqueue to start p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p99") }, :lower_better],
      ["Enqueue to finish p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p95") }, :lower_better],
      ["Enqueue to finish p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p99") }, :lower_better],
      ["DB CPU avg (%)", ->(m) { m.dig("db_cpu", "avg_pct") }, :lower_better],
      ["DB CPU max (%)", ->(m) { m.dig("db_cpu", "max_pct") }, :lower_better]
    ].freeze

    module_function

    def run(argv, root:)
      force = argv.delete("--force") ? true : false
      a_path, b_path = argv
      abort "usage: bin/bench compare <a/result.json> <b/result.json> [--force]" unless a_path && b_path

      a = Result.load(a_path)
      b = Result.load(b_path)
      out_dir = File.join(root, "reports", "#{a.run_id}__vs__#{b.run_id}")
      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "report.md"), render_markdown(a, b, force: force))
      File.write(File.join(out_dir, "report.html"), render_html(a, b, force: force))
      puts "reports written to #{out_dir}"
    end

    def render_markdown(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      lines = []
      lines << "# solid_queue benchmark comparison"
      lines << ""
      lines << "> #{warning.gsub("\n", " ")}" if warning
      lines << "| | A | B |"
      lines << "|---|---|---|"
      lines << "| Run | #{a.run_id} | #{b.run_id} |"
      lines << "| Database | #{a.database} | #{b.database} |"
      lines << "| Source | #{source_label(a)} | #{source_label(b)} |"
      lines << "| Scenario | #{scenario_label(a)} | #{scenario_label(b)} |"
      lines << "| Profile | #{a.profile} | #{b.profile} |"
      lines << ""
      lines << "## Metrics (B relative to A)"
      lines << ""
      lines << "| Metric | A | B | Delta |"
      lines << "|---|---:|---:|---:|"
      METRIC_ROWS.each do |label, extractor, direction|
        av = extractor.call(a.metrics)
        bv = extractor.call(b.metrics)
        lines << "| #{label} | #{fmt(av)} | #{fmt(bv)} | #{delta(av, bv, direction)} |"
      end
      lines << ""
      lines << "## Top statements by total DB time"
      append_statement_table(lines, "A", a)
      append_statement_table(lines, "B", b)
      lines.join("\n") + "\n"
    end

    def render_html(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      cpu_chart = SvgChart.line_chart(
        title: "DB CPU %",
        y_label: "DB CPU %",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#2563eb", points: normalize_series(a.metrics.dig("db_cpu", "series"), "cpu_pct") },
          { label: "B: #{b.source["spec"]}", color: "#dc2626", points: normalize_series(b.metrics.dig("db_cpu", "series"), "cpu_pct") }
        ]
      )
      depth_chart = SvgChart.line_chart(
        title: "Ready queue depth",
        y_label: "ready executions",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#2563eb", points: normalize_series(a.metrics["queue_depth_series"], "ready") },
          { label: "B: #{b.source["spec"]}", color: "#dc2626", points: normalize_series(b.metrics["queue_depth_series"], "ready") }
        ]
      )
      md = render_markdown(a, b, force: true)

      <<~HTML
        <!doctype html>
        <meta charset="utf-8">
        <title>solid_queue benchmark: #{h(a.run_id)} vs #{h(b.run_id)}</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 920px; margin: 2rem auto; padding: 0 1rem; color: #0f172a; }
          h1, h2 { line-height: 1.15; }
          pre { background: #f8fafc; border: 1px solid #e2e8f0; padding: 1rem; overflow-x: auto; white-space: pre-wrap; }
          svg { width: 100%; height: auto; border: 1px solid #e2e8f0; margin: 0.75rem 0 1.5rem; }
          .warning { border-left: 4px solid #f59e0b; padding: 0.75rem 1rem; background: #fffbeb; }
        </style>
        <h1>solid_queue benchmark comparison</h1>
        #{warning ? %(<p class="warning"><strong>#{h(warning).gsub("\n", "<br>")}</strong></p>) : ""}
        <h2>DB CPU over time</h2>
        #{cpu_chart}
        <h2>Ready queue depth over time</h2>
        #{depth_chart}
        <h2>Full comparison markdown</h2>
        <pre>#{h(md)}</pre>
      HTML
    end

    def check_profiles!(a, b, force:)
      pa = comparable_profile(a.profile)
      pb = comparable_profile(b.profile)
      return nil if pa == pb

      message = "PROFILES DIFFER: this comparison mixes topology and gem changes.\nA: #{pa}\nB: #{pb}"
      raise ProfileMismatch, message unless force
      message
    end

    def comparable_profile(profile)
      profile.reject { |k, _| k.to_s == "name" }
    end

    def delta(a_val, b_val, direction)
      return "" if a_val.nil? || b_val.nil? || a_val.to_f.zero?

      pct = ((b_val.to_f - a_val.to_f) / a_val.to_f * 100).round(1)
      sign = pct.positive? ? "+" : ""
      better = direction == :higher_better ? pct.positive? : pct.negative?
      "#{sign}#{pct}% #{better ? "better" : "worse"}"
    end

    def fmt(value)
      value.nil? ? "-" : value
    end

    def source_label(result)
      sha = result.source["sha"]
      short_sha = sha ? ", #{sha[0, 12]}" : ""
      "#{result.source["spec"]} (#{result.source["resolved_version"]}#{short_sha})"
    end

    def scenario_label(result)
      "#{result.scenario["name"]} #{result.scenario["params"]}"
    end

    def append_statement_table(lines, tag, result)
      lines << ""
      lines << "### #{tag}: #{result.run_id}"
      lines << ""
      lines << "| Statement | Count | Total ms | Rows examined |"
      lines << "|---|---:|---:|---:|"
      Array(result.metrics["top_statements"]).first(10).each do |statement|
        text = statement["digest_text"].to_s.gsub("|", "\\|").gsub("`", "")[0, 120]
        lines << "| `#{text}` | #{statement["count"]} | #{statement["total_ms"]} | #{statement["rows_examined"]} |"
      end
    end

    def normalize_series(series, key)
      series = Array(series)
      return [] if series.empty?

      t0 = series.first["t"]
      series.map { |sample| [(sample["t"] - t0).round(1), sample[key].to_f] }
    end

    def h(str)
      CGI.escapeHTML(str.to_s)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- ruby -Ilib -Itest test/compare_test.rb`
Expected: `5 runs, 8 assertions, 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/compare.rb test/compare_test.rb
git commit -m "feat: show database engine in compare reports; rename mysql_cpu to db_cpu"
```

---

### Task 9: Add a `postgres` service to `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`

Not unit-testable via Minitest — verified with a YAML parse check (no Docker required) and, if Docker is available, `docker compose config`.

- [ ] **Step 1: Replace the file**

Replace `docker-compose.yml` in full:

```yaml
name: sq-bench

services:
  mysql:
    image: mysql:8.0
    container_name: sq-bench-mysql
    environment:
      MYSQL_ROOT_PASSWORD: bench
      MYSQL_DATABASE: bench
    command: --performance-schema=ON --max-connections=500
    cpus: "${BENCH_DB_CPUS:-1.0}"
    mem_limit: "${BENCH_DB_MEMORY:-1g}"
    ports:
      - "127.0.0.1:${BENCH_MYSQL_PORT:-13306}:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-pbench"]
      interval: 2s
      timeout: 2s
      retries: 60

  postgres:
    image: postgres:16
    container_name: sq-bench-postgres
    environment:
      POSTGRES_USER: bench
      POSTGRES_PASSWORD: bench
      POSTGRES_DB: bench
    command: postgres -c shared_preload_libraries=pg_stat_statements -c max_connections=500
    cpus: "${BENCH_DB_CPUS:-1.0}"
    mem_limit: "${BENCH_DB_MEMORY:-1g}"
    ports:
      - "127.0.0.1:${BENCH_POSTGRES_PORT:-15432}:5432"
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "bench"]
      interval: 2s
      timeout: 2s
      retries: 60
```

- [ ] **Step 2: Verify it's valid YAML**

Run: `mise exec -- ruby -ryaml -e 'YAML.load_file("docker-compose.yml"); puts "ok"'`
Expected: `ok`

- [ ] **Step 3: If Docker is available, verify Compose accepts it**

Run: `docker compose config --quiet`
Expected: exits `0` with no output. (Skip this step if Docker isn't installed in your environment — Task 14's manual smoke test will exercise it end-to-end.)

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add postgres service to docker-compose.yml"
```

---

### Task 10: Make `database.yml` adapter-aware

**Files:**
- Modify: `harness/config/database.yml`

- [ ] **Step 1: Replace the file**

Replace `harness/config/database.yml` in full:

```erb
<% engine = ENV.fetch("BENCH_DATABASE", "mysql") %>
production:
<% if engine == "postgres" %>
  adapter: postgresql
  host: 127.0.0.1
  port: <%= ENV.fetch("BENCH_POSTGRES_PORT", 15432).to_i %>
  username: bench
  password: bench
  database: bench
<% else %>
  adapter: trilogy
  host: 127.0.0.1
  port: <%= ENV.fetch("BENCH_MYSQL_PORT", 13306).to_i %>
  username: root
  password: bench
  database: bench
<% end %>
  pool: <%= ENV.fetch("BENCH_WORKER_THREADS", 2).to_i + 3 %>
```

- [ ] **Step 2: Verify it renders correctly for both engines**

Run:

```bash
mise exec -- ruby -rerb -ryaml -e '
  template = File.read("harness/config/database.yml")
  ["mysql", "postgres"].each do |engine|
    ENV["BENCH_DATABASE"] = engine
    rendered = ERB.new(template).result
    config = YAML.load(rendered)
    puts "#{engine}: adapter=#{config.dig("production", "adapter")} port=#{config.dig("production", "port")}"
  end
'
```

Expected:
```
mysql: adapter=trilogy port=13306
postgres: adapter=postgresql port=15432
```

- [ ] **Step 3: Commit**

```bash
git add harness/config/database.yml
git commit -m "feat: select database adapter via BENCH_DATABASE"
```

---

### Task 11: Add the `pg` gem to the harness `Gemfile`

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Add the gem**

In `Gemfile`, change:

```ruby
gem "trilogy"
```

to:

```ruby
gem "trilogy"
gem "pg"
```

- [ ] **Step 2: Syntax-check the file**

Run: `mise exec -- ruby -c Gemfile`
Expected: `Syntax OK`

Actually installing this (`bundle install`) requires network access and, since `pg` has a native extension, `libpq` dev headers on the host (see `README.md` prerequisites, updated in Task 13). Full `bundle install` is exercised by Task 14's manual smoke test, not by this task.

- [ ] **Step 3: Commit**

```bash
git add Gemfile
git commit -m "feat: add pg gem for Postgres adapter support"
```

---

### Task 12: Make `db_setup.rb` adapter-aware

**Files:**
- Modify: `harness/script/db_setup.rb`

- [ ] **Step 1: Replace the file**

Replace `harness/script/db_setup.rb` in full:

```ruby
# harness/script/db_setup.rb
db_config = ActiveRecord::Base.connection_db_config.configuration_hash
adapter_name = ActiveRecord::Base.connection.adapter_name

if adapter_name == "PostgreSQL"
  ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
else
  ActiveRecord::Base.establish_connection(db_config.merge(database: nil))
  ActiveRecord::Base.connection.execute("CREATE DATABASE IF NOT EXISTS #{db_config[:database]}")
  ActiveRecord::Base.establish_connection(db_config)
end

gem_path = Gem.loaded_specs["solid_queue"].full_gem_path
schema_candidates = [
  File.join(gem_path, "db", "queue_schema.rb"),
  File.join(gem_path, "lib", "generators", "solid_queue", "install", "templates", "db", "queue_schema.rb")
]
queue_schema = schema_candidates.find { |path| File.exist?(path) }
raise "Could not find solid_queue queue_schema.rb (looked in: #{schema_candidates.join(', ')})" unless queue_schema
load queue_schema

ActiveRecord::Schema.define do
  create_table :bench_events, force: true do |t|
    t.string :job_id, null: false
    t.string :job_class, null: false
    t.string :queue_name
    t.integer :priority, default: 0
    t.datetime :enqueued_at, precision: 6
    t.datetime :started_at, precision: 6
    t.datetime :finished_at, precision: 6
  end
end

puts "db_setup: ok (solid_queue schema from #{queue_schema})"
```

- [ ] **Step 2: Syntax-check the file**

Run: `mise exec -- ruby -c harness/script/db_setup.rb`
Expected: `Syntax OK`

This script only runs meaningfully inside `bin/rails runner` against a live database connection, so it can't be exercised standalone — Task 14's manual smoke test covers both branches end-to-end.

- [ ] **Step 3: Commit**

```bash
git add harness/script/db_setup.rb
git commit -m "feat: make db_setup adapter-aware for Postgres"
```

---

### Task 13: Update `README.md` and `mise.toml`

**Files:**
- Modify: `README.md`
- Modify: `mise.toml`

- [ ] **Step 1: Update the prerequisites section**

In `README.md`, change:

```markdown
## Prerequisites

- [mise](https://mise.jdx.dev) for the pinned Ruby version
- Docker for MySQL 8.0

Workers run on the host. Only MySQL is containerized.
```

to:

```markdown
## Prerequisites

- [mise](https://mise.jdx.dev) for the pinned Ruby version
- Docker for MySQL 8.0 and Postgres 16
- `libpq` dev headers on the host, to compile the `pg` gem's native extension
  (`libpq-dev` on Debian/Ubuntu, `postgresql` via Homebrew on macOS)

Workers run on the host. Only the database (MySQL or Postgres) is containerized.
```

- [ ] **Step 2: Update the setup description**

Change:

```markdown
`setup` bundles the default upstream source and pulls the MySQL image.
```

to:

```markdown
`setup` bundles the default upstream source and pulls both the MySQL and Postgres images.
```

- [ ] **Step 3: Update the "Run a Benchmark" section**

Change:

```markdown
## Run a Benchmark

```sh
# latest official gem
bin/bench run baseline --source upstream

# pinned RubyGems release
bin/bench run baseline --source upstream@1.2.4

# local fork; must be clean unless --allow-dirty is passed
bin/bench run sprawl --source path:~/Projects/solid_queue
```

Each run starts a fresh MySQL volume, loads schema from the selected gem source, starts the
solid_queue supervisor, runs the scenario, waits for drain, and writes
`results/<run-id>/result.json` plus logs. Results include the resolved gem version and, for
`path:` sources, the git SHA.
```

to:

```markdown
## Run a Benchmark

```sh
# latest official gem, against MySQL (default)
bin/bench run baseline --source upstream

# same run against Postgres, for a like-for-like comparison
bin/bench run baseline --source upstream --database postgres

# pinned RubyGems release
bin/bench run baseline --source upstream@1.2.4

# local fork; must be clean unless --allow-dirty is passed
bin/bench run sprawl --source path:~/Projects/solid_queue
```

Each run starts a fresh database volume (MySQL or Postgres, per `--database`; default `mysql`),
loads schema from the selected gem source, starts the solid_queue supervisor, runs the scenario,
waits for drain, and writes `results/<run-id>/result.json` plus logs. Results include the
resolved gem version, the database engine used, and, for `path:` sources, the git SHA.
```

- [ ] **Step 4: Update the "Profiles and Topology" section**

Change:

```markdown
## Profiles and Topology

Profiles live in `profiles/*.yml` and bundle MySQL resources with worker topology so comparisons
stay comparable. The default profile uses MySQL pinned to 1 CPU / 1 GB, 10 worker processes x 2
threads, and 1 dispatcher.

```sh
bin/bench run baseline --source upstream --profile default
bin/bench run baseline --source upstream --profile smoke
bin/bench run baseline --source upstream --workers 50 --mysql-cpus 2 --mysql-memory 2g
```

`bin/bench compare` refuses profile mismatches unless `--force` is passed.
```

to:

```markdown
## Profiles and Topology

Profiles live in `profiles/*.yml` and bundle database resource limits with worker topology so
comparisons stay comparable, independent of which engine a run targets. The default profile
pins the database container to 1 CPU / 1 GB, with 10 worker processes x 2 threads and 1
dispatcher.

```sh
bin/bench run baseline --source upstream --profile default
bin/bench run baseline --source upstream --profile smoke
bin/bench run baseline --source upstream --workers 50 --db-cpus 2 --db-memory 2g
bin/bench run baseline --source upstream --database postgres --profile default
```

`bin/bench compare` refuses profile mismatches unless `--force` is passed. Comparing a MySQL run
against a Postgres run under the same profile is not treated as a mismatch — the report simply
shows which engine each side used.
```

- [ ] **Step 5: Update the "Compare Runs" section**

Change:

```markdown
Reports are written to `reports/<A>__vs__<B>/report.md` and `report.html`. They include metric
deltas, MySQL CPU and ready-depth overlay charts, and top SQL statements by total database time.
```

to:

```markdown
Reports are written to `reports/<A>__vs__<B>/report.md` and `report.html`. They include which
database engine each run used, metric deltas, DB CPU and ready-depth overlay charts, and top SQL
statements by total database time.
```

- [ ] **Step 6: Update the "Metrics" section**

Change:

```markdown
## Metrics

- Throughput, including a per-second series
- Latency percentiles for enqueue-to-start and enqueue-to-finish
- MySQL container CPU samples from `docker stats`
- Queue depth samples for ready, scheduled, claimed, blocked, failed, and completed jobs
- Top statement digests from MySQL `performance_schema`
```

to:

```markdown
## Metrics

- Throughput, including a per-second series
- Latency percentiles for enqueue-to-start and enqueue-to-finish
- Database container CPU samples from `docker stats`
- Queue depth samples for ready, scheduled, claimed, blocked, failed, and completed jobs
- Top statement digests from MySQL `performance_schema` or Postgres `pg_stat_statements`
```

- [ ] **Step 7: Update the mise setup task description**

In `mise.toml`, change:

```toml
[tasks.setup]
description = "Install gems for the default (upstream) source and pull the MySQL image"
run = "mise exec -- ruby bin/bench setup"
```

to:

```toml
[tasks.setup]
description = "Install gems for the default (upstream) source and pull the MySQL and Postgres images"
run = "mise exec -- ruby bin/bench setup"
```

- [ ] **Step 8: Commit**

```bash
git add README.md mise.toml
git commit -m "docs: document postgres support in README and mise tasks"
```

---

### Task 14: Manual end-to-end verification

**Files:** none (verification only)

Automated tests cover every unit in isolation, but `Runner`'s orchestration (Docker Compose, the Rails harness, `bundle install` with the new `pg` gem) has no automated coverage, matching the existing project pattern where this is verified manually via `mise run smoke`. This task is the Postgres equivalent of that.

- [ ] **Step 1: Run the full test suite one more time**

Run: `mise exec -- ruby -Ilib -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'`
Expected: all tests pass, `0 failures, 0 errors`.

- [ ] **Step 2: Install gems (exercises the new `pg` gem's native extension)**

Run: `mise run setup`
Expected: completes without error, ending in `setup: ok`. If it fails compiling `pg`, install `libpq` dev headers per the updated README prerequisites and retry.

- [ ] **Step 3: Confirm the existing MySQL smoke path still works (regression check)**

Run: `mise run smoke`
Expected: ends with `completed: results/<run-id>/result.json`.

- [ ] **Step 4: Run the same smoke scenario against Postgres**

Run:

```bash
mise exec -- ruby bin/bench run baseline --source upstream --database postgres --profile smoke --set jobs=100 --set rate=100 --set work_ms=0 --timeout 180
```

Expected: ends with `completed: results/<run-id>/result.json`, where `<run-id>` contains `-postgres-`.

- [ ] **Step 5: Compare the two results**

Run: `bin/bench list` to find both result paths, then:

```bash
mise exec -- ruby bin/bench compare results/<mysql-run-id>/result.json results/<postgres-run-id>/result.json
```

Expected: `reports written to reports/<A>__vs__<B>`, and `reports/<A>__vs__<B>/report.md` contains a `| Database | mysql | postgres |` row and no `PROFILES DIFFER` warning (since both used the `smoke` profile).

- [ ] **Step 6: Spot-check the HTML report**

Open `reports/<A>__vs__<B>/report.html` and confirm it renders two SVG charts titled "DB CPU %" and "Ready queue depth", plus the full markdown comparison.

If any step fails, use the `superpowers:systematic-debugging` skill rather than guessing at a fix.

---

## Self-review notes

- **Spec coverage:** every "Changed files"/"New files" bullet in the spec maps to a task above (Engines → Task 2, PostgresClient → Task 1, docker-compose.yml → Task 9, database.yml → Task 10, Gemfile → Task 11, db_setup.rb → Task 12, Profile/profiles → Task 3, Digests → Task 4, Runner → Task 6, CLI → Task 7, Result → Task 5, Compare → Task 8, README/mise.toml → Task 13). The spec's manual-verification note is Task 14.
- **Placeholder scan:** no TODOs; every step shows complete code or an exact command with expected output.
- **Type/name consistency:** `Engines.fetch(name).{client_class,container,service,port_env,default_port,digest_reset_sql,digest_fetch_sql}` is defined once in Task 2 and used with those exact names in Task 6 (`Runner`) and Task 7 (`CLI`, indirectly via `Engines.names`). `Profile#db_cpus`/`#db_memory` defined in Task 3 are used with those names in Task 7's CLI header line. `Result#database` defined in Task 5 is used in Task 6 (`Runner`) and Task 8 (`Compare`). The metrics key `db_cpu` is renamed consistently in Task 6 (`Runner#build_metrics`), Task 7 (`CLI#list`), and Task 8 (`Compare::METRIC_ROWS` and chart data).
