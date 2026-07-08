# Solid Queue Benchmark Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a benchmark harness that runs solid_queue workloads against either the official gem or a local fork, producing traceable JSON results and comparison reports (spec: `docs/superpowers/specs/2026-07-08-solid-queue-benchmark-design.md`).

**Architecture:** A stdlib-only Ruby orchestrator (`bin/bench` + `lib/bench/`) shells out to Docker Compose (MySQL 8.0, resource-pinned), Bundler (per-source lockfiles via wrapper gemfiles), and a minimal Rails app (`harness/`) whose solid_queue supervisor forks workers locally. Metrics come from a `bench_events` table, a `docker stats` sampler, a queue-depth sampler, and `performance_schema` digest capture.

**Tech Stack:** Ruby 3.3 (mise), Rails 8.0 (railties/activerecord/activejob only), trilogy adapter (no host mysql libs), MySQL 8.0 in Docker, Minitest for unit tests.

**Conventions used throughout:**
- Repo root: `/Users/lukesmith/Projects/solid-queue-benchmark` — all paths below are relative to it.
- The orchestrator (`bin/bench`, `lib/bench/**`) uses **stdlib only** (json, yaml, optparse, open3, fileutils, time). It must never `require "bundler/setup"` — it *manages* bundles for the harness via env vars.
- Unit tests run with plain `ruby -Ilib -Itest test/<file>.rb` (minitest is a bundled gem in Ruby 3.3; no Gemfile needed for the orchestrator tests).
- All MySQL access from the orchestrator goes through `docker compose exec` — no mysql client on the host.
- Commit after every task with the message given in the task.

---

### Task 1: Repo scaffolding (mise, gitignore, compose, Gemfile, test bootstrap)

**Files:**
- Create: `mise.toml`
- Create: `.gitignore`
- Create: `docker-compose.yml`
- Create: `Gemfile`
- Create: `test/test_helper.rb`
- Create: `profiles/default.yml`
- Create: `profiles/smoke.yml`

- [ ] **Step 1: Write `mise.toml`**

```toml
[tools]
ruby = "3.3"

[tasks.setup]
description = "Install gems for the default (upstream) source and pull the MySQL image"
run = "bin/bench setup"

[tasks.bench]
description = "Proxy to bin/bench (e.g. mise run bench -- run baseline --source upstream)"
run = "bin/bench"

[tasks.test]
description = "Run orchestrator unit tests"
run = "ruby -Ilib -Itest -e 'Dir.glob(\"test/**/*_test.rb\").sort.each { |f| require File.expand_path(f) }'"

[tasks.smoke]
description = "Tiny end-to-end run to verify the pipeline"
run = "bin/bench run baseline --source upstream --profile smoke --set jobs=100 --set rate=100 --set work_ms=0 --timeout 180"
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
results/
reports/
gemfiles/
harness/log/
harness/tmp/
.bundle/
*.lock
```

- [ ] **Step 3: Write `docker-compose.yml`**

MySQL resource limits come from env vars the orchestrator sets from the profile. `performance_schema` is on by default in MySQL 8 but we pass it explicitly so it can never silently regress.

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
    cpus: "${BENCH_MYSQL_CPUS:-1.0}"
    mem_limit: "${BENCH_MYSQL_MEMORY:-1g}"
    ports:
      - "127.0.0.1:${BENCH_MYSQL_PORT:-13306}:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-pbench"]
      interval: 2s
      timeout: 2s
      retries: 60
```

- [ ] **Step 4: Write `Gemfile`**

The solid_queue source branches on `SOLID_QUEUE_SOURCE` (set by wrapper gemfiles in `gemfiles/`, see Task 2). Trilogy avoids any host MySQL client libraries.

```ruby
source "https://rubygems.org"

gem "railties", "~> 8.0.0"
gem "activerecord", "~> 8.0.0"
gem "activejob", "~> 8.0.0"
gem "trilogy"

case (sq_source = ENV.fetch("SOLID_QUEUE_SOURCE", "upstream"))
when "upstream"
  gem "solid_queue"
when /\Aupstream@(.+)\z/
  gem "solid_queue", Regexp.last_match(1)
when /\Apath:(.+)\z/
  gem "solid_queue", path: File.expand_path(Regexp.last_match(1))
else
  raise "Unknown SOLID_QUEUE_SOURCE: #{sq_source.inspect}"
end
```

- [ ] **Step 5: Write `test/test_helper.rb`**

```ruby
require "minitest/autorun"
```

- [ ] **Step 6: Write `profiles/default.yml`**

```yaml
# Baseline profile: MySQL deliberately small so contention shows at light load,
# preserving the production pressure ratio (many pollers per DB core).
mysql:
  cpus: 1.0
  memory: 1g
workers:
  count: 10
  threads: 2
  polling_interval: 0.1
dispatcher:
  count: 1
```

- [ ] **Step 7: Write `profiles/smoke.yml`**

```yaml
mysql:
  cpus: 1.0
  memory: 1g
workers:
  count: 2
  threads: 2
  polling_interval: 0.1
dispatcher:
  count: 1
```

- [ ] **Step 8: Verify mise picks up the config**

Run: `mise install && mise ls --current`
Expected: ruby 3.3.x listed and active for this directory.

- [ ] **Step 9: Commit**

```bash
git add mise.toml .gitignore docker-compose.yml Gemfile test/ profiles/
git commit -m "feat: repo scaffolding — mise, compose, Gemfile, profiles"
```

---

### Task 2: Source spec parsing and wrapper gemfiles (TDD)

Parses `SOLID_QUEUE_SOURCE` strings, derives per-source lockfile keys, generates wrapper gemfiles, and reads git SHA/dirty state for `path:` sources.

**Files:**
- Create: `lib/bench/source_spec.rb`
- Test: `test/source_spec_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/source_spec_test.rb
require "test_helper"
require "bench/source_spec"
require "tmpdir"

class SourceSpecTest < Minitest::Test
  def test_parses_upstream_latest
    spec = Bench::SourceSpec.parse("upstream")
    assert_equal :upstream, spec.kind
    assert_nil spec.version
    assert_equal "upstream-latest", spec.key
    assert_equal "upstream", spec.to_s
  end

  def test_parses_upstream_pinned
    spec = Bench::SourceSpec.parse("upstream@1.2.4")
    assert_equal :upstream, spec.kind
    assert_equal "1.2.4", spec.version
    assert_equal "upstream-1.2.4", spec.key
    assert_equal "upstream@1.2.4", spec.to_s
  end

  def test_parses_path
    spec = Bench::SourceSpec.parse("path:~/Projects/solid_queue")
    assert_equal :path, spec.kind
    assert_equal File.expand_path("~/Projects/solid_queue"), spec.path
    assert_equal "path-solid_queue", spec.key
    assert_equal "path:#{File.expand_path("~/Projects/solid_queue")}", spec.to_s
  end

  def test_rejects_garbage
    assert_raises(ArgumentError) { Bench::SourceSpec.parse("gem:whatever") }
  end

  def test_wrapper_gemfile_pins_env_and_evals_root_gemfile
    spec = Bench::SourceSpec.parse("upstream@1.2.4")
    contents = spec.wrapper_gemfile_contents
    assert_includes contents, %(ENV["SOLID_QUEUE_SOURCE"] = "upstream@1.2.4")
    assert_includes contents, %(eval_gemfile File.expand_path("../Gemfile", __dir__))
  end

  def test_git_info_for_clean_and_dirty_repo
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q")
      File.write(File.join(dir, "a.txt"), "hello")
      system("git", "-C", dir, "add", ".")
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

      spec = Bench::SourceSpec.parse("path:#{dir}")
      assert_match(/\A[0-9a-f]{40}\z/, spec.git_sha)
      refute spec.git_dirty?

      File.write(File.join(dir, "b.txt"), "dirty")
      assert spec.git_dirty?
    end
  end

  def test_git_info_nil_for_upstream
    spec = Bench::SourceSpec.parse("upstream")
    assert_nil spec.git_sha
    refute spec.git_dirty?
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/source_spec_test.rb`
Expected: FAIL — `cannot load such file -- bench/source_spec`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/bench/source_spec.rb
require "open3"

module Bench
  SourceSpec = Struct.new(:kind, :version, :path, keyword_init: true) do
    def self.parse(str)
      case str
      when "upstream"
        new(kind: :upstream)
      when /\Aupstream@(.+)\z/
        new(kind: :upstream, version: Regexp.last_match(1))
      when /\Apath:(.+)\z/
        new(kind: :path, path: File.expand_path(Regexp.last_match(1)))
      else
        raise ArgumentError, "invalid source spec: #{str.inspect} (expected upstream, upstream@VERSION, or path:DIR)"
      end
    end

    def key
      kind == :path ? "path-#{File.basename(path)}" : "upstream-#{version || "latest"}"
    end

    def to_s
      kind == :path ? "path:#{path}" : (version ? "upstream@#{version}" : "upstream")
    end

    def wrapper_gemfile_contents
      <<~RUBY
        ENV["SOLID_QUEUE_SOURCE"] = #{to_s.inspect}
        eval_gemfile File.expand_path("../Gemfile", __dir__)
      RUBY
    end

    def git_sha
      return nil unless kind == :path
      out, status = Open3.capture2("git", "-C", path, "rev-parse", "HEAD")
      status.success? ? out.strip : nil
    end

    def git_dirty?
      return false unless kind == :path
      out, status = Open3.capture2("git", "-C", path, "status", "--porcelain")
      status.success? && !out.strip.empty?
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/source_spec_test.rb`
Expected: PASS (7 assertions groups, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/bench/source_spec.rb test/source_spec_test.rb
git commit -m "feat: source spec parsing, wrapper gemfiles, git traceability"
```

---

### Task 3: Profile loading with overrides (TDD)

**Files:**
- Create: `lib/bench/profile.rb`
- Test: `test/profile_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/profile_test.rb
require "test_helper"
require "bench/profile"

class ProfileTest < Minitest::Test
  def test_loads_default_profile_by_name
    p = Bench::Profile.load("default")
    assert_equal 1.0, p.mysql_cpus
    assert_equal "1g", p.mysql_memory
    assert_equal 10, p.workers
    assert_equal 2, p.threads
    assert_equal 0.1, p.polling_interval
    assert_equal 1, p.dispatchers
  end

  def test_cli_overrides_win
    p = Bench::Profile.load("default", workers: 50, mysql_cpus: 2.0)
    assert_equal 50, p.workers
    assert_equal 2.0, p.mysql_cpus
    assert_equal 2, p.threads # untouched
  end

  def test_env_map
    p = Bench::Profile.load("smoke")
    assert_equal(
      {
        "BENCH_MYSQL_CPUS" => "1.0",
        "BENCH_MYSQL_MEMORY" => "1g",
        "BENCH_WORKER_PROCESSES" => "2",
        "BENCH_WORKER_THREADS" => "2",
        "BENCH_POLLING_INTERVAL" => "0.1"
      },
      p.env
    )
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

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/profile_test.rb`
Expected: FAIL — `cannot load such file -- bench/profile`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/bench/profile.rb
require "yaml"

module Bench
  class Profile
    ATTRS = %i[name mysql_cpus mysql_memory workers threads polling_interval dispatchers].freeze
    attr_reader(*ATTRS)

    # name_or_path: a bare profile name resolved under profiles/, or a path to a yml.
    # overrides: {workers:, threads:, mysql_cpus:, mysql_memory:} from CLI flags.
    def self.load(name_or_path, overrides = {})
      path = if name_or_path.include?("/") || name_or_path.end_with?(".yml")
        File.expand_path(name_or_path)
      else
        File.expand_path("../../profiles/#{name_or_path}.yml", __dir__)
      end
      raw = YAML.safe_load_file(path)
      new(
        name: File.basename(path, ".yml"),
        mysql_cpus: (overrides[:mysql_cpus] || raw.dig("mysql", "cpus") || 1.0).to_f,
        mysql_memory: (overrides[:mysql_memory] || raw.dig("mysql", "memory") || "1g").to_s,
        workers: (overrides[:workers] || raw.dig("workers", "count") || 10).to_i,
        threads: (overrides[:threads] || raw.dig("workers", "threads") || 2).to_i,
        polling_interval: (raw.dig("workers", "polling_interval") || 0.1).to_f,
        dispatchers: (raw.dig("dispatcher", "count") || 1).to_i
      )
    end

    def initialize(name:, mysql_cpus:, mysql_memory:, workers:, threads:, polling_interval:, dispatchers:)
      @name = name
      @mysql_cpus = mysql_cpus
      @mysql_memory = mysql_memory
      @workers = workers
      @threads = threads
      @polling_interval = polling_interval
      @dispatchers = dispatchers
    end

    def env
      {
        "BENCH_MYSQL_CPUS" => mysql_cpus.to_s,
        "BENCH_MYSQL_MEMORY" => mysql_memory,
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/profile_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/bench/profile.rb test/profile_test.rb
git commit -m "feat: topology profiles with CLI overrides and env mapping"
```

---

### Task 4: Stats helpers — percentiles and per-second bucketing (TDD)

**Files:**
- Create: `lib/bench/stats.rb`
- Test: `test/stats_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
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

  def test_per_second_buckets
    # unix timestamps: three events in second 100, one in second 102
    ts = [100.1, 100.5, 100.9, 102.3]
    assert_equal [[100, 3], [101, 0], [102, 1]], Bench::Stats.per_second(ts)
    assert_equal [], Bench::Stats.per_second([])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/stats_test.rb`
Expected: FAIL — `cannot load such file -- bench/stats`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/bench/stats.rb
module Bench
  module Stats
    module_function

    def percentile(values, p)
      return nil if values.empty?
      sorted = values.sort
      rank = (p / 100.0) * (sorted.length - 1)
      lo = sorted[rank.floor]
      hi = sorted[rank.ceil]
      lo + (hi - lo) * (rank - rank.floor)
    end

    def summary(values)
      return { count: 0 } if values.empty?
      {
        count: values.length,
        mean: (values.sum / values.length.to_f).round(2),
        p50: percentile(values, 50)&.round(2),
        p95: percentile(values, 95)&.round(2),
        p99: percentile(values, 99)&.round(2),
        max: values.max.round(2)
      }
    end

    # timestamps: array of unix-time floats -> [[second, count], ...] with gaps zero-filled
    def per_second(timestamps)
      return [] if timestamps.empty?
      counts = timestamps.group_by { |t| t.to_i }.transform_values(&:length)
      (counts.keys.min..counts.keys.max).map { |sec| [sec, counts.fetch(sec, 0)] }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/stats_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/bench/stats.rb test/stats_test.rb
git commit -m "feat: stats helpers — percentiles, summaries, per-second buckets"
```

---

### Task 5: Scenario definitions (TDD)

Scenario metadata lives orchestrator-side: parameter defaults, expected job totals (for drain detection), and validation. The actual enqueueing happens in the harness driver (Task 7).

**Files:**
- Create: `lib/bench/scenarios.rb`
- Test: `test/scenarios_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/scenarios_test.rb
require "test_helper"
require "bench/scenarios"

class ScenariosTest < Minitest::Test
  def test_baseline_defaults
    s = Bench::Scenarios.build("baseline", {})
    assert_equal({ "jobs" => 20_000, "rate" => 500, "work_ms" => 50, "duration" => 60 }, s.params)
    assert_equal 20_000, s.expected_total
  end

  def test_baseline_param_overrides_are_typed
    s = Bench::Scenarios.build("baseline", { "jobs" => "100", "work_ms" => "0" })
    assert_equal 100, s.params["jobs"]
    assert_equal 0, s.params["work_ms"]
    assert_equal 100, s.expected_total
  end

  def test_baseline_idle_variant
    s = Bench::Scenarios.build("baseline", { "jobs" => "0" })
    assert_equal 0, s.expected_total
  end

  def test_sprawl_expected_total_is_geometric
    s = Bench::Scenarios.build("sprawl", {})
    # 100 seeds * (1 + 50 + 50^2) = 255,100
    assert_equal 255_100, s.expected_total
    small = Bench::Scenarios.build("sprawl", { "seeds" => "2", "fanout" => "3", "depth" => "1" })
    assert_equal 8, small.expected_total # 2 * (1 + 3)
  end

  def test_unknown_scenario_raises
    assert_raises(ArgumentError) { Bench::Scenarios.build("nope", {}) }
  end

  def test_unknown_param_raises
    assert_raises(ArgumentError) { Bench::Scenarios.build("baseline", { "bogus" => "1" }) }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/scenarios_test.rb`
Expected: FAIL — `cannot load such file -- bench/scenarios`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/bench/scenarios.rb
module Bench
  module Scenarios
    Scenario = Struct.new(:name, :params, :expected_total, keyword_init: true)

    DEFINITIONS = {
      "baseline" => {
        # duration only applies when jobs == 0 (pure idle-polling measurement)
        defaults: { "jobs" => 20_000, "rate" => 500, "work_ms" => 50, "duration" => 60 },
        expected: ->(p) { p["jobs"] }
      },
      "sprawl" => {
        defaults: { "seeds" => 100, "fanout" => 50, "depth" => 2, "work_ms" => 10 },
        expected: ->(p) { p["seeds"] * (0..p["depth"]).sum { |i| p["fanout"]**i } }
      }
    }.freeze

    def self.build(name, raw_params)
      defn = DEFINITIONS[name] or raise ArgumentError,
        "unknown scenario #{name.inspect} (available: #{DEFINITIONS.keys.join(", ")})"
      unknown = raw_params.keys - defn[:defaults].keys
      raise ArgumentError, "unknown params for #{name}: #{unknown.join(", ")}" if unknown.any?

      params = defn[:defaults].merge(raw_params.transform_values(&:to_i))
      Scenario.new(name: name, params: params, expected_total: defn[:expected].call(params))
    end

    def self.names = DEFINITIONS.keys
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/scenarios_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/bench/scenarios.rb test/scenarios_test.rb
git commit -m "feat: scenario definitions with typed params and expected totals"
```

---

### Task 6: Shell runner, MySQL client, digests, samplers (TDD where pure)

All external commands funnel through `Bench::Shell` so everything above it is testable with a fake runner.

**Files:**
- Create: `lib/bench/shell.rb`
- Create: `lib/bench/mysql_client.rb`
- Create: `lib/bench/digests.rb`
- Create: `lib/bench/samplers.rb`
- Test: `test/mysql_client_test.rb`
- Test: `test/digests_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# test/mysql_client_test.rb
require "test_helper"
require "bench/mysql_client"

class MysqlClientTest < Minitest::Test
  def test_query_parses_tsv_rows
    fake = lambda do |cmd, env: {}|
      assert_equal %w[docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e], cmd[0..-2]
      assert_equal "SELECT 1, 'a'", cmd.last
      "1\ta\n2\tb\n"
    end
    client = Bench::MysqlClient.new(runner: fake)
    assert_equal [["1", "a"], ["2", "b"]], client.query("SELECT 1, 'a'")
  end

  def test_scalar
    client = Bench::MysqlClient.new(runner: ->(_cmd, env: {}) { "42\n" })
    assert_equal "42", client.scalar("SELECT COUNT(*) FROM t")
  end

  def test_scalar_nil_on_empty
    client = Bench::MysqlClient.new(runner: ->(_cmd, env: {}) { "" })
    assert_nil client.scalar("SELECT 1 WHERE FALSE")
  end
end
```

```ruby
# test/digests_test.rb
require "test_helper"
require "bench/digests"

class DigestsTest < Minitest::Test
  FakeClient = Struct.new(:rows) do
    def query(sql) = sql.start_with?("TRUNCATE") ? [] : rows
  end

  def test_fetch_maps_rows
    rows = [["SELECT * FROM `solid_queue_ready_executions` ...", "1500", "2345.6", "150000"]]
    digests = Bench::Digests.new(client: FakeClient.new(rows))
    result = digests.fetch
    assert_equal 1, result.length
    assert_equal "SELECT * FROM `solid_queue_ready_executions` ...", result[0][:digest_text]
    assert_equal 1500, result[0][:count]
    assert_equal 2345.6, result[0][:total_ms]
    assert_equal 150_000, result[0][:rows_examined]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/mysql_client_test.rb && ruby -Ilib -Itest test/digests_test.rb`
Expected: FAIL — cannot load files

- [ ] **Step 3: Write `lib/bench/shell.rb`**

```ruby
# lib/bench/shell.rb
require "open3"

module Bench
  module Shell
    Error = Class.new(StandardError)

    module_function

    # Run a command, return stdout. Raises Bench::Shell::Error on non-zero exit.
    def capture(cmd, env: {})
      stdout, stderr, status = Open3.capture3(env, *cmd)
      unless status.success?
        raise Error, "command failed (#{status.exitstatus}): #{cmd.join(" ")}\n#{stderr}"
      end
      stdout
    end

    # Run a command streaming output to a log file; returns the pid.
    def spawn_logged(cmd, env: {}, log_path:, chdir: nil)
      log = File.open(log_path, "a")
      opts = { out: log, err: log }
      opts[:chdir] = chdir if chdir
      pid = Process.spawn(env, *cmd, **opts)
      log.close
      pid
    end
  end
end
```

- [ ] **Step 4: Write `lib/bench/mysql_client.rb`**

```ruby
# lib/bench/mysql_client.rb
require "bench/shell"

module Bench
  class MysqlClient
    BASE_CMD = %w[docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e].freeze

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

- [ ] **Step 5: Write `lib/bench/digests.rb`**

```ruby
# lib/bench/digests.rb
module Bench
  class Digests
    FETCH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e9, 1), SUM_ROWS_EXAMINED
      FROM performance_schema.events_statements_summary_by_digest
      WHERE SCHEMA_NAME = 'bench'
      ORDER BY SUM_TIMER_WAIT DESC
      LIMIT 20
    SQL

    def initialize(client:)
      @client = client
    end

    # Zero the digest table. Called after workers register, before enqueue starts,
    # so captured stats cover steady-state benchmark activity only.
    def reset
      @client.query("TRUNCATE performance_schema.events_statements_summary_by_digest")
    end

    def fetch
      @client.query(FETCH_SQL).map do |text, count, total_ms, rows_examined|
        { digest_text: text, count: count.to_i, total_ms: total_ms.to_f, rows_examined: rows_examined.to_i }
      end
    end
  end
end
```

- [ ] **Step 6: Write `lib/bench/samplers.rb`**

Two background samplers. `CpuSampler` reads a streaming `docker stats` process (one JSON line ~every second when stdout is not a TTY). `DepthSampler` polls queue tables. Both tolerate transient errors (tables not yet created, container restarting) by skipping the sample.

```ruby
# lib/bench/samplers.rb
require "json"

module Bench
  class CpuSampler
    attr_reader :samples

    def initialize(container: "sq-bench-mysql")
      @container = container
      @samples = []
    end

    def start
      @io = IO.popen(["docker", "stats", "--format", "{{json .}}", @container], "r")
      @thread = Thread.new do
        @io.each_line do |line|
          # docker interleaves ANSI clear codes even in some non-TTY contexts; strip to the JSON
          json_start = line.index("{")
          next unless json_start
          data = JSON.parse(line[json_start..]) rescue next
          cpu = data["CPUPerc"].to_s.delete("%").to_f
          @samples << { "t" => Time.now.to_f.round(1), "cpu_pct" => cpu }
        end
      end
      self
    end

    def stop
      Process.kill("TERM", @io.pid) rescue nil
      @io.close rescue nil
      @thread&.join(5)
      @samples
    end
  end

  class DepthSampler
    DEPTH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT
        (SELECT COUNT(*) FROM solid_queue_ready_executions),
        (SELECT COUNT(*) FROM solid_queue_scheduled_executions),
        (SELECT COUNT(*) FROM solid_queue_claimed_executions),
        (SELECT COUNT(*) FROM solid_queue_blocked_executions),
        (SELECT COUNT(*) FROM bench_events)
    SQL

    attr_reader :samples

    def initialize(client:, interval: 1.0)
      @client = client
      @interval = interval
      @samples = []
      @stop = false
    end

    def start
      @thread = Thread.new do
        until @stop
          begin
            row = @client.query(DEPTH_SQL).first
            if row
              @samples << {
                "t" => Time.now.to_f.round(1),
                "ready" => row[0].to_i, "scheduled" => row[1].to_i,
                "claimed" => row[2].to_i, "blocked" => row[3].to_i,
                "completed" => row[4].to_i
              }
            end
          rescue StandardError
            # transient: skip this sample
          end
          sleep @interval
        end
      end
      self
    end

    def latest = @samples.last

    def stop
      @stop = true
      @thread&.join(@interval + 5)
      @samples
    end
  end
end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mise run test`
Expected: PASS — all tests from Tasks 2–6 green

- [ ] **Step 8: Commit**

```bash
git add lib/bench/shell.rb lib/bench/mysql_client.rb lib/bench/digests.rb lib/bench/samplers.rb test/mysql_client_test.rb test/digests_test.rb
git commit -m "feat: shell runner, mysql client, digest capture, cpu/depth samplers"
```

---

### Task 7: Minimal Rails harness app

The harness is a hand-rolled minimal Rails app: ActiveRecord + ActiveJob + solid_queue, no web server. Job timings land in `bench_events` via an `around_perform` callback. All topology knobs read from `BENCH_*` env vars (set by the orchestrator from the profile).

**Files:**
- Create: `harness/config/boot.rb`
- Create: `harness/config/application.rb`
- Create: `harness/config/environment.rb`
- Create: `harness/config/database.yml`
- Create: `harness/config/queue.yml`
- Create: `harness/bin/rails`
- Create: `harness/bin/jobs`
- Create: `harness/app/models/application_record.rb`
- Create: `harness/app/models/bench_event.rb`
- Create: `harness/app/jobs/application_job.rb`
- Create: `harness/app/jobs/baseline_job.rb`
- Create: `harness/app/jobs/sprawl_job.rb`
- Create: `harness/script/db_setup.rb`

- [ ] **Step 1: Write `harness/config/boot.rb`**

```ruby
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)
require "bundler/setup"
```

- [ ] **Step 2: Write `harness/config/application.rb`**

```ruby
require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module BenchHarness
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = true
    config.secret_key_base = "bench-harness-not-secret"
    config.active_job.queue_adapter = :solid_queue
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
```

- [ ] **Step 3: Write `harness/config/environment.rb`**

```ruby
require_relative "application"
Rails.application.initialize!
```

- [ ] **Step 4: Write `harness/config/database.yml`**

Pool sized to worker threads plus solid_queue's internal threads (heartbeat, polling).

```yaml
production:
  adapter: trilogy
  host: 127.0.0.1
  port: <%= ENV.fetch("BENCH_MYSQL_PORT", 13306).to_i %>
  username: root
  password: bench
  database: bench
  pool: <%= ENV.fetch("BENCH_WORKER_THREADS", 2).to_i + 3 %>
```

- [ ] **Step 5: Write `harness/config/queue.yml`**

The supervisor forks `processes` workers × `threads` each on the wildcard queue, plus dedicated dispatchers — mirroring production (dedicated scheduling pod, wildcard workers).

```yaml
production:
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: "*"
      threads: <%= ENV.fetch("BENCH_WORKER_THREADS", 2).to_i %>
      processes: <%= ENV.fetch("BENCH_WORKER_PROCESSES", 10).to_i %>
      polling_interval: <%= ENV.fetch("BENCH_POLLING_INTERVAL", 0.1).to_f %>
```

- [ ] **Step 6: Write `harness/bin/rails` and `harness/bin/jobs`**

```ruby
#!/usr/bin/env ruby
# harness/bin/rails
APP_PATH = File.expand_path("../config/application", __dir__)
require_relative "../config/boot"
require "rails/commands"
```

```ruby
#!/usr/bin/env ruby
# harness/bin/jobs
require_relative "../config/environment"
require "solid_queue/cli"
SolidQueue::Cli.start(ARGV)
```

Run: `chmod +x harness/bin/rails harness/bin/jobs`

- [ ] **Step 7: Write the models**

```ruby
# harness/app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
```

```ruby
# harness/app/models/bench_event.rb
class BenchEvent < ApplicationRecord
end
```

- [ ] **Step 8: Write the jobs**

```ruby
# harness/app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    started_at = Time.current
    block.call
    BenchEvent.insert({
      job_id: job.job_id,
      job_class: job.class.name,
      queue_name: job.queue_name,
      priority: job.priority || 0,
      enqueued_at: job.enqueued_at,
      started_at: started_at,
      finished_at: Time.current
    })
  end
end
```

```ruby
# harness/app/jobs/baseline_job.rb
class BaselineJob < ApplicationJob
  def perform(work_ms)
    sleep(work_ms / 1000.0) if work_ms.positive?
  end
end
```

```ruby
# harness/app/jobs/sprawl_job.rb
# Fan-out: each job with depth > 0 enqueues `fanout` children one at a time
# (per-insert enqueue path, as real sprawling jobs do), cycling priorities so
# the wildcard-queue priority ordering is exercised under burst.
class SprawlJob < ApplicationJob
  PRIORITIES = [0, 10, 20].freeze

  def perform(depth:, fanout:, work_ms:)
    if depth.positive?
      fanout.times do |i|
        SprawlJob.set(priority: PRIORITIES[i % PRIORITIES.size])
                 .perform_later(depth: depth - 1, fanout: fanout, work_ms: work_ms)
      end
    end
    sleep(work_ms / 1000.0) if work_ms.positive?
  end
end
```

- [ ] **Step 9: Write `harness/script/db_setup.rb`**

Loads the solid_queue schema **from whichever gem source is bundled** — the fork's schema changes (new indexes, tables) are automatically honored. Run via `bin/rails runner`.

```ruby
# harness/script/db_setup.rb
db_config = ActiveRecord::Base.connection_db_config.configuration_hash

ActiveRecord::Base.establish_connection(db_config.merge(database: nil))
ActiveRecord::Base.connection.execute("CREATE DATABASE IF NOT EXISTS #{db_config[:database]}")
ActiveRecord::Base.establish_connection(db_config)

queue_schema = File.join(Gem.loaded_specs["solid_queue"].full_gem_path, "db", "queue_schema.rb")
load queue_schema

ActiveRecord::Schema.define do
  create_table :bench_events, if_not_exists: true do |t|
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

- [ ] **Step 10: Verify the harness boots end-to-end (manual integration check)**

```bash
# 1. bundle for the default source
mkdir -p gemfiles
cat > gemfiles/upstream-latest.gemfile <<'EOF'
ENV["SOLID_QUEUE_SOURCE"] = "upstream"
eval_gemfile File.expand_path("../Gemfile", __dir__)
EOF
BUNDLE_GEMFILE=$PWD/gemfiles/upstream-latest.gemfile bundle install

# 2. MySQL up
docker compose up -d --wait

# 3. schema
cd harness && BUNDLE_GEMFILE=$PWD/../gemfiles/upstream-latest.gemfile RAILS_ENV=production bundle exec bin/rails runner script/db_setup.rb && cd ..

# 4. enqueue one job and run a worker briefly
cd harness && BUNDLE_GEMFILE=$PWD/../gemfiles/upstream-latest.gemfile RAILS_ENV=production bundle exec bin/rails runner 'BaselineJob.perform_later(0)' && cd ..
cd harness && BUNDLE_GEMFILE=$PWD/../gemfiles/upstream-latest.gemfile RAILS_ENV=production BENCH_WORKER_PROCESSES=1 timeout 15 bundle exec bin/jobs start; cd ..

# 5. verify the event landed
docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e "SELECT job_class, TIMESTAMPDIFF(MICROSECOND, enqueued_at, finished_at) FROM bench_events"
```

Expected: last command prints `BaselineJob` and a positive microsecond latency. (The `timeout 15` kill of `bin/jobs` exits non-zero — that's fine.)

- [ ] **Step 11: Tear down and commit**

```bash
docker compose down -v
git add harness/
git commit -m "feat: minimal Rails harness with instrumented benchmark jobs"
```

---

### Task 8: Scenario driver script

Runs inside the harness (`bin/rails runner`), reads a JSON scenario file written by the orchestrator, and enqueues load. Baseline paces enqueues with `perform_all_later` ticks; sprawl seeds a burst.

**Files:**
- Create: `harness/script/drive.rb`

- [ ] **Step 1: Write `harness/script/drive.rb`**

```ruby
# harness/script/drive.rb
# Input: BENCH_SCENARIO_FILE -> {"scenario": "baseline", "params": {...}}
require "json"

spec = JSON.parse(File.read(ENV.fetch("BENCH_SCENARIO_FILE")))
params = spec.fetch("params")

case spec.fetch("scenario")
when "baseline"
  jobs = params.fetch("jobs")
  if jobs.zero?
    # Idle variant: measure pure polling cost with no work in the system.
    sleep params.fetch("duration")
  else
    rate = params.fetch("rate")
    work_ms = params.fetch("work_ms")
    tick = 0.1
    per_tick = [(rate * tick).ceil, 1].max
    enqueued = 0
    while enqueued < jobs
      batch_size = [per_tick, jobs - enqueued].min
      tick_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveJob.perform_all_later(Array.new(batch_size) { BaselineJob.new(work_ms) })
      enqueued += batch_size
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - tick_started
      sleep([tick - elapsed, 0].max)
    end
  end
when "sprawl"
  seeds = Array.new(params.fetch("seeds")) do
    SprawlJob.new(depth: params.fetch("depth"), fanout: params.fetch("fanout"), work_ms: params.fetch("work_ms"))
  end
  ActiveJob.perform_all_later(seeds)
else
  abort "drive.rb: unknown scenario #{spec["scenario"].inspect}"
end

puts "drive.rb: enqueue complete"
```

- [ ] **Step 2: Verify manually with MySQL up**

```bash
docker compose up -d --wait
cd harness && BUNDLE_GEMFILE=$PWD/../gemfiles/upstream-latest.gemfile RAILS_ENV=production bundle exec bin/rails runner script/db_setup.rb
echo '{"scenario":"baseline","params":{"jobs":50,"rate":100,"work_ms":0,"duration":60}}' > /tmp/scenario.json
BENCH_SCENARIO_FILE=/tmp/scenario.json BUNDLE_GEMFILE=$PWD/../gemfiles/upstream-latest.gemfile RAILS_ENV=production bundle exec bin/rails runner script/drive.rb
cd ..
docker compose exec -T mysql mysql -uroot -pbench -N -B bench -e "SELECT COUNT(*) FROM solid_queue_jobs"
docker compose down -v
```

Expected: `drive.rb: enqueue complete`, then `50`.

- [ ] **Step 3: Commit**

```bash
git add harness/script/drive.rb
git commit -m "feat: scenario driver — paced baseline enqueue and sprawl seeding"
```

---

### Task 9: Result building and persistence (TDD)

**Files:**
- Create: `lib/bench/result.rb`
- Test: `test/result_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/result_test.rb`
Expected: FAIL — `cannot load such file -- bench/result`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/bench/result.rb
require "json"
require "fileutils"

module Bench
  class Result
    FIELDS = %i[run_id scenario source profile status error timings metrics].freeze
    attr_accessor(*FIELDS)

    def initialize(**attrs)
      FIELDS.each { |f| public_send("#{f}=", attrs[f]) }
    end

    def self.load(path)
      data = JSON.parse(File.read(path))
      new(**FIELDS.to_h { |f| [f, data[f.to_s]] })
    end

    def to_h = FIELDS.to_h { |f| [f, public_send(f)] }

    def write(results_dir:)
      dir = File.join(results_dir, run_id)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "result.json")
      File.write(path, JSON.pretty_generate(to_h))
      path
    end

    def logs_dir(results_dir:)
      dir = File.join(results_dir, run_id, "logs")
      FileUtils.mkdir_p(dir)
      dir
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/result_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/bench/result.rb test/result_test.rb
git commit -m "feat: result JSON persistence with per-run logs dir"
```

---

### Task 10: Run orchestration (Runner)

The integration core: executes the full data flow from the spec. Thin on logic (all logic already unit-tested); verified by the smoke run in Task 12.

**Files:**
- Create: `lib/bench/runner.rb`

- [ ] **Step 1: Write `lib/bench/runner.rb`**

```ruby
# lib/bench/runner.rb
require "json"
require "fileutils"
require "time"
require "bench/shell"
require "bench/mysql_client"
require "bench/digests"
require "bench/samplers"
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
        digest_rows = @digests.fetch
        stop_supervisor(supervisor_pid)

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

    # --- gem source ---

    def prepare_source
      if @source.kind == :path && @source.git_dirty? && !@allow_dirty
        raise RunFailure, "fork working tree is dirty at #{@source.path} — commit, or pass --allow-dirty"
      end
      FileUtils.mkdir_p(File.join(@root, "gemfiles"))
      File.write(gemfile_path, @source.wrapper_gemfile_contents)
      begin
        Shell.capture(%w[bundle check], env: base_env)
      rescue Shell::Error
        Shell.capture(%w[bundle install], env: base_env)
      end
      build_source_info
    end

    def build_source_info
      version = Shell.capture(
        ["bundle", "exec", "ruby", "-e", 'require "solid_queue/version"; print SolidQueue::VERSION'],
        env: base_env
      ).strip
      sha = @source.git_sha
      sha = "#{sha}+dirty" if sha && @source.git_dirty?
      { spec: @source.to_s, resolved_version: version, sha: sha, dirty: @source.git_dirty? }
    end

    # --- infrastructure ---

    def mysql_fresh_start
      compose_down
      Shell.capture(%w[docker compose up -d --wait], env: @profile.env.merge("BENCH_MYSQL_PORT" => mysql_port))
    end

    def compose_down
      Shell.capture(%w[docker compose down -v], env: @profile.env.merge("BENCH_MYSQL_PORT" => mysql_port))
    end

    def mysql_port = ENV.fetch("BENCH_MYSQL_PORT", "13306")

    def db_setup(logs)
      Shell.capture(
        %w[bundle exec bin/rails runner script/db_setup.rb].then { |cmd| cmd },
        env: base_env.merge("BUNDLE_GEMFILE" => gemfile_path)
      ).tap { |out| File.write(File.join(logs, "db_setup.log"), out) }
    end

    # --- processes ---

    def start_supervisor(logs)
      Shell.spawn_logged(
        %w[bundle exec bin/jobs start],
        env: base_env, chdir: harness_dir,
        log_path: File.join(logs, "supervisor.log")
      )
    end

    def stop_supervisor(pid)
      Process.kill("TERM", pid)
      60.times do
        Process.waitpid(pid, Process::WNOHANG) and return
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
        %w[bundle exec bin/rails runner script/drive.rb],
        env: base_env.merge("BENCH_SCENARIO_FILE" => scenario_file),
        chdir: harness_dir, log_path: File.join(logs, "driver.log")
      )
      _, status = Process.waitpid2(pid)
      raise RunFailure, "scenario driver failed (see logs/driver.log)" unless status.success?
    end

    def wait_for_drain(depth_sampler)
      return if @scenario.expected_total.zero?
      deadline = Time.now + @timeout
      loop do
        snap = depth_sampler.latest
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

      {
        completed_jobs: rows.length,
        throughput_jobs_per_sec: (rows.length / wall).round(2),
        throughput_series: Stats.per_second(finished_ts),
        latency_ms: {
          enqueue_to_start: Stats.summary(to_start),
          enqueue_to_finish: Stats.summary(to_finish)
        },
        mysql_cpu: {
          avg_pct: cpu_values.empty? ? nil : (cpu_values.sum / cpu_values.length).round(1),
          max_pct: cpu_values.max,
          series: cpu_samples
        },
        queue_depth_series: depth_samples,
        top_statements: digest_rows
      }
    end
  end
end
```

- [ ] **Step 2: Syntax check**

Run: `ruby -Ilib -c lib/bench/runner.rb`
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add lib/bench/runner.rb
git commit -m "feat: run orchestration — full benchmark data flow"
```

---

### Task 11: CLI (`bin/bench`) with run/list/setup commands

**Files:**
- Create: `bin/bench`
- Create: `lib/bench/cli.rb`
- Test: `test/cli_test.rb`

- [ ] **Step 1: Write the failing test (option parsing only — commands are integration-tested by smoke)**

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
  end

  def test_run_requires_scenario_and_source
    assert_raises(ArgumentError) { Bench::CLI.parse_run_options(%w[--source upstream]) }
    assert_raises(ArgumentError) { Bench::CLI.parse_run_options(%w[baseline]) }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/cli_test.rb`
Expected: FAIL — `cannot load such file -- bench/cli`

- [ ] **Step 3: Write `lib/bench/cli.rb`**

```ruby
# lib/bench/cli.rb
require "optparse"
require "json"
require "bench/source_spec"
require "bench/profile"
require "bench/scenarios"

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
        puts <<~USAGE
          Usage: bin/bench <command>
            run <scenario> --source <src> [options]   Run a benchmark
            compare <result.json> <result.json>       Compare two runs
            list                                      List past runs
            setup                                     Bundle default source + pull MySQL image

          Scenarios: #{Scenarios.names.join(", ")}
          Sources:   upstream | upstream@1.2.4 | path:/dir/of/solid_queue
        USAGE
        exit(argv.empty? ? 0 : 1)
      end
    end

    def parse_run_options(argv)
      opts = { profile: "default", params: {}, overrides: {}, timeout: 900, repeat: 1, allow_dirty: false }
      parser = OptionParser.new do |o|
        o.on("--source SRC") { |v| opts[:source] = v }
        o.on("--profile NAME") { |v| opts[:profile] = v }
        o.on("--set KEY=VAL", "Scenario param override (repeatable)") do |v|
          k, val = v.split("=", 2)
          opts[:params][k] = val
        end
        o.on("--workers N", Integer) { |v| opts[:overrides][:workers] = v }
        o.on("--threads N", Integer) { |v| opts[:overrides][:threads] = v }
        o.on("--mysql-cpus N", Float) { |v| opts[:overrides][:mysql_cpus] = v }
        o.on("--mysql-memory SIZE") { |v| opts[:overrides][:mysql_memory] = v }
        o.on("--timeout SECONDS", Integer) { |v| opts[:timeout] = v }
        o.on("--repeat N", Integer) { |v| opts[:repeat] = v }
        o.on("--allow-dirty") { opts[:allow_dirty] = true }
      end
      positional = parser.parse(argv)
      opts[:scenario] = positional.first
      raise ArgumentError, "scenario required (#{Scenarios.names.join(", ")})" unless opts[:scenario]
      raise ArgumentError, "--source required" unless opts[:source]
      opts
    end

    def run(argv)
      require "bench/runner"
      opts = parse_run_options(argv)
      scenario = Scenarios.build(opts[:scenario], opts[:params])
      source = SourceSpec.parse(opts[:source])
      profile = Profile.load(opts[:profile], opts[:overrides])

      results = opts[:repeat].times.map do |i|
        puts "== run #{i + 1}/#{opts[:repeat]}: #{scenario.name} | #{source} | profile #{profile.name}" \
             " (#{profile.workers}w x #{profile.threads}t, mysql #{profile.mysql_cpus}cpu)"
        Runner.new(scenario: scenario, source: source, profile: profile,
                   root: ROOT, timeout: opts[:timeout], allow_dirty: opts[:allow_dirty]).call
      end

      if opts[:repeat] > 1
        completed = results.select { |r| r.status == "completed" }
        throughputs = completed.map { |r| r.metrics[:throughput_jobs_per_sec] }.sort
        puts "== #{completed.length}/#{results.length} completed; median throughput: #{throughputs[throughputs.length / 2]} jobs/sec"
      end
      exit(results.all? { |r| r.status == "completed" } ? 0 : 1)
    end

    def list
      Dir.glob(File.join(ROOT, "results", "*", "result.json")).sort.each do |path|
        data = JSON.parse(File.read(path))
        m = data["metrics"] || {}
        puts format("%-55s %-9s %8s jobs/sec  cpu avg %s%%",
                    data["run_id"], data["status"],
                    m["throughput_jobs_per_sec"] || "-",
                    m.dig("mysql_cpu", "avg_pct") || "-")
      end
    end

    def setup
      require "bench/runner"
      require "bench/shell"
      require "fileutils"
      source = SourceSpec.parse("upstream")
      FileUtils.mkdir_p(File.join(ROOT, "gemfiles"))
      gemfile = File.join(ROOT, "gemfiles", "#{source.key}.gemfile")
      File.write(gemfile, source.wrapper_gemfile_contents)
      Shell.capture(%w[bundle install], env: { "BUNDLE_GEMFILE" => gemfile })
      Shell.capture(%w[docker compose pull mysql])
      puts "setup: ok"
    end

    def compare(argv)
      require "bench/compare"
      Compare.run(argv, root: ROOT)
    end
  end
end
```

- [ ] **Step 4: Write `bin/bench`**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "bench/cli"
Bench::CLI.start(ARGV)
```

Run: `chmod +x bin/bench`

- [ ] **Step 5: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/cli_test.rb`
Expected: PASS. Also run `bin/bench` with no args — expect the usage text (compare will fail to load until Task 13; that's expected only if invoked).

- [ ] **Step 6: Commit**

```bash
git add bin/bench lib/bench/cli.rb test/cli_test.rb
git commit -m "feat: bench CLI — run, list, setup commands"
```

---

### Task 12: End-to-end smoke run

Exercise the full pipeline for real. Expect fallout — this is the task where integration bugs surface and get fixed.

**Files:**
- Modify: whatever the smoke run flushes out

- [ ] **Step 1: Run setup then the smoke benchmark**

```bash
mise run setup
mise run smoke
```

Expected: exits 0; prints `completed: results/<run-id>/result.json`.

- [ ] **Step 2: Inspect the result JSON for sanity**

```bash
cat results/*baseline-upstream-latest/result.json | ruby -rjson -e '
  r = JSON.parse(STDIN.read)
  raise "status: #{r["status"]} — #{r["error"]}" unless r["status"] == "completed"
  m = r["metrics"]
  raise "wrong job count: #{m["completed_jobs"]}" unless m["completed_jobs"] == 100
  raise "no cpu samples" if m["mysql_cpu"]["series"].empty?
  raise "no depth samples" if m["queue_depth_series"].empty?
  raise "no digests" if m["top_statements"].empty?
  raise "no source version" if r["source"]["resolved_version"].to_s.empty?
  puts "smoke OK: #{m["throughput_jobs_per_sec"]} jobs/sec, cpu avg #{m["mysql_cpu"]["avg_pct"]}%"
'
```

Expected: `smoke OK: ...`. Fix any failures before proceeding (check `results/<run>/logs/*.log`).

- [ ] **Step 3: Verify the fork source path works too**

```bash
bin/bench run baseline --source path:$HOME/Projects/solid_queue --profile smoke --set jobs=100 --set rate=100 --set work_ms=0 --timeout 180
```

Expected: exits 0; result JSON `source.sha` is a 40-char SHA (or run refuses with the dirty-tree message if the fork is dirty — that refusal is also a pass for this step; then retry with `--allow-dirty` and confirm `sha` ends in `+dirty`).

- [ ] **Step 4: Verify `list`**

Run: `bin/bench list`
Expected: one line per run with status/throughput/cpu.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration fallout from first end-to-end smoke runs"
```

---

### Task 13: Compare command with markdown + HTML reports (TDD for rendering)

> **Implementer note:** before writing the SVG/HTML chart code in this task, invoke the `dataviz` skill and apply its palette/axis/legend guidance to the chart helper.

**Files:**
- Create: `lib/bench/compare.rb`
- Create: `lib/bench/svg_chart.rb`
- Test: `test/compare_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/compare_test.rb
require "test_helper"
require "bench/compare"
require "bench/result"

class CompareTest < Minitest::Test
  def result(overrides = {})
    base = {
      run_id: "20260708-a", status: "completed", error: nil,
      scenario: { "name" => "baseline", "params" => { "jobs" => 100 }, "expected_total" => 100 },
      source: { "spec" => "upstream", "resolved_version" => "1.2.4", "sha" => nil, "dirty" => false },
      profile: { "name" => "smoke", "workers" => 2, "threads" => 2, "mysql_cpus" => 1.0 },
      timings: { "wall_seconds" => 10.0 },
      metrics: {
        "completed_jobs" => 100,
        "throughput_jobs_per_sec" => 50.0,
        "latency_ms" => {
          "enqueue_to_start" => { "p50" => 20.0, "p95" => 80.0, "p99" => 120.0 },
          "enqueue_to_finish" => { "p50" => 25.0, "p95" => 90.0, "p99" => 130.0 }
        },
        "mysql_cpu" => { "avg_pct" => 40.0, "max_pct" => 70.0, "series" => [{ "t" => 1.0, "cpu_pct" => 40.0 }] },
        "queue_depth_series" => [{ "t" => 1.0, "ready" => 5, "scheduled" => 0, "claimed" => 2, "blocked" => 0, "completed" => 10 }],
        "top_statements" => [{ "digest_text" => "SELECT ...", "count" => 100, "total_ms" => 50.0, "rows_examined" => 200 }]
      }
    }
    Bench::Result.new(**base.merge(overrides))
  end

  def test_refuses_mismatched_profiles_without_force
    b = result(profile: { "name" => "default", "workers" => 10, "threads" => 2, "mysql_cpus" => 1.0 })
    assert_raises(Bench::Compare::ProfileMismatch) do
      Bench::Compare.render_markdown(result, b, force: false)
    end
  end

  def test_force_allows_mismatched_profiles
    b = result(profile: { "name" => "default", "workers" => 10, "threads" => 2, "mysql_cpus" => 1.0 })
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

  def test_html_contains_svg_charts
    html = Bench::Compare.render_html(result, result(run_id: "20260708-b"), force: false)
    assert_includes html, "<svg"
    assert_includes html, "MySQL CPU"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/compare_test.rb`
Expected: FAIL — `cannot load such file -- bench/compare`

- [ ] **Step 3: Write `lib/bench/svg_chart.rb`** *(invoke the dataviz skill first; adjust colors/styling per its guidance)*

```ruby
# lib/bench/svg_chart.rb
module Bench
  module SvgChart
    W = 720
    H = 240
    PAD = 40

    module_function

    # series: [{label:, color:, points: [[x, y], ...]}]
    def line_chart(title:, series:, y_label: "")
      all = series.flat_map { |s| s[:points] }
      return "<p>(no data: #{title})</p>" if all.empty?

      x_min, x_max = all.map(&:first).minmax
      y_min = 0.0
      y_max = [all.map(&:last).max, 1.0].max
      x_span = [x_max - x_min, 0.001].max

      sx = ->(x) { PAD + (x - x_min) / x_span * (W - 2 * PAD) }
      sy = ->(y) { H - PAD - (y - y_min) / (y_max - y_min) * (H - 2 * PAD) }

      polylines = series.map do |s|
        pts = s[:points].map { |x, y| "#{sx.call(x).round(1)},#{sy.call(y).round(1)}" }.join(" ")
        %(<polyline fill="none" stroke="#{s[:color]}" stroke-width="1.5" points="#{pts}"/>)
      end

      legend = series.each_with_index.map do |s, i|
        %(<text x="#{PAD + i * 180}" y="16" fill="#{s[:color]}" font-size="12">■ #{s[:label]}</text>)
      end

      <<~SVG
        <svg viewBox="0 0 #{W} #{H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="#{title}">
          <text x="#{W / 2}" y="#{H - 6}" text-anchor="middle" font-size="11" fill="#666">seconds</text>
          <text x="12" y="#{H / 2}" font-size="11" fill="#666" transform="rotate(-90 12 #{H / 2})" text-anchor="middle">#{y_label}</text>
          <line x1="#{PAD}" y1="#{H - PAD}" x2="#{W - PAD}" y2="#{H - PAD}" stroke="#999"/>
          <line x1="#{PAD}" y1="#{PAD}" x2="#{PAD}" y2="#{H - PAD}" stroke="#999"/>
          <text x="#{PAD - 4}" y="#{PAD + 4}" text-anchor="end" font-size="10" fill="#666">#{y_max.round(1)}</text>
          <text x="#{PAD - 4}" y="#{H - PAD}" text-anchor="end" font-size="10" fill="#666">0</text>
          #{legend.join("\n")}
          #{polylines.join("\n")}
        </svg>
      SVG
    end
  end
end
```

- [ ] **Step 4: Write `lib/bench/compare.rb`**

```ruby
# lib/bench/compare.rb
require "fileutils"
require "bench/result"
require "bench/svg_chart"

module Bench
  module Compare
    ProfileMismatch = Class.new(StandardError)

    METRIC_ROWS = [
      ["Throughput (jobs/sec)", ->(m) { m["throughput_jobs_per_sec"] }, :higher_better],
      ["Enqueue→start p50 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p50") }, :lower_better],
      ["Enqueue→start p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p95") }, :lower_better],
      ["Enqueue→start p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p99") }, :lower_better],
      ["Enqueue→finish p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p95") }, :lower_better],
      ["Enqueue→finish p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p99") }, :lower_better],
      ["MySQL CPU avg (%)", ->(m) { m.dig("mysql_cpu", "avg_pct") }, :lower_better],
      ["MySQL CPU max (%)", ->(m) { m.dig("mysql_cpu", "max_pct") }, :lower_better]
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

    def check_profiles!(a, b, force:)
      pa = a.profile.reject { |k, _| k.to_s == "name" }
      pb = b.profile.reject { |k, _| k.to_s == "name" }
      return nil if pa == pb
      msg = "PROFILES DIFFER — this comparison mixes topology and gem changes:\nA: #{pa}\nB: #{pb}"
      raise ProfileMismatch, msg unless force
      msg
    end

    def delta(a_val, b_val, direction)
      return "" if a_val.nil? || b_val.nil? || a_val.zero?
      pct = ((b_val - a_val) / a_val.to_f * 100).round(1)
      sign = pct.positive? ? "+" : ""
      good = (direction == :higher_better) == pct.positive?
      "#{sign}#{pct}% #{good ? "✅" : "🔻"}"
    end

    def render_markdown(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      lines = []
      lines << "# solid_queue benchmark comparison"
      lines << ""
      lines << "> ⚠️ #{warning.gsub("\n", " ")}" if warning
      lines << "| | A | B |"
      lines << "|---|---|---|"
      lines << "| Run | #{a.run_id} | #{b.run_id} |"
      lines << "| Source | #{a.source["spec"]} (#{a.source["resolved_version"]}#{a.source["sha"] ? ", #{a.source["sha"][0, 12]}" : ""}) | #{b.source["spec"]} (#{b.source["resolved_version"]}#{b.source["sha"] ? ", #{b.source["sha"][0, 12]}" : ""}) |"
      lines << "| Scenario | #{a.scenario["name"]} #{a.scenario["params"]} | #{b.scenario["name"]} #{b.scenario["params"]} |"
      lines << "| Profile | #{a.profile} | #{b.profile} |"
      lines << ""
      lines << "## Metrics (B relative to A)"
      lines << ""
      lines << "| Metric | A | B | Δ |"
      lines << "|---|---|---|---|"
      METRIC_ROWS.each do |label, extractor, direction|
        av = extractor.call(a.metrics)
        bv = extractor.call(b.metrics)
        lines << "| #{label} | #{av || "-"} | #{bv || "-"} | #{delta(av, bv, direction)} |"
      end
      lines << ""
      lines << "## Top statements by total DB time"
      [["A", a], ["B", b]].each do |tag, r|
        lines << ""
        lines << "### #{tag}: #{r.run_id}"
        lines << ""
        lines << "| Statement | Count | Total ms | Rows examined |"
        lines << "|---|---|---|---|"
        (r.metrics["top_statements"] || []).first(10).each do |s|
          text = s["digest_text"].to_s.gsub("|", "\\|")[0, 120]
          lines << "| `#{text}` | #{s["count"]} | #{s["total_ms"]} | #{s["rows_examined"]} |"
        end
      end
      lines.join("\n") + "\n"
    end

    def render_html(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      cpu_chart = SvgChart.line_chart(
        title: "MySQL CPU %", y_label: "MySQL CPU %",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#4569d4", points: normalize_series(a.metrics.dig("mysql_cpu", "series"), "cpu_pct") },
          { label: "B: #{b.source["spec"]}", color: "#d4562e", points: normalize_series(b.metrics.dig("mysql_cpu", "series"), "cpu_pct") }
        ]
      )
      depth_chart = SvgChart.line_chart(
        title: "Ready queue depth", y_label: "ready executions",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#4569d4", points: normalize_series(a.metrics["queue_depth_series"], "ready") },
          { label: "B: #{b.source["spec"]}", color: "#d4562e", points: normalize_series(b.metrics["queue_depth_series"], "ready") }
        ]
      )
      md_table = render_markdown(a, b, force: true)
      <<~HTML
        <meta charset="utf-8">
        <title>solid_queue benchmark: #{a.run_id} vs #{b.run_id}</title>
        <style>
          body { font-family: -apple-system, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; }
          pre { background: #f6f6f6; padding: 1rem; overflow-x: auto; }
          svg { width: 100%; height: auto; border: 1px solid #ddd; margin: 1rem 0; }
        </style>
        <h1>solid_queue benchmark comparison</h1>
        #{warning ? "<p><strong>⚠️ #{warning.gsub("\n", "<br>")}</strong></p>" : ""}
        <h2>MySQL CPU over time</h2>
        #{cpu_chart}
        <h2>Ready queue depth over time</h2>
        #{depth_chart}
        <h2>Full comparison (markdown)</h2>
        <pre>#{md_table.gsub("<", "&lt;")}</pre>
      HTML
    end

    # Convert [{t:, key:}, ...] to [[seconds-from-start, value], ...]
    def normalize_series(series, key)
      series = Array(series)
      return [] if series.empty?
      t0 = series.first["t"]
      series.map { |s| [(s["t"] - t0).round(1), s[key].to_f] }
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/compare_test.rb && mise run test`
Expected: PASS, full suite green.

- [ ] **Step 6: Integration check with real results from Task 12**

```bash
bin/bench compare results/<upstream-run>/result.json results/<fork-run>/result.json
open reports/*/report.html
```

Expected: reports written; HTML shows two overlay charts and the delta table.

- [ ] **Step 7: Commit**

```bash
git add lib/bench/compare.rb lib/bench/svg_chart.rb test/compare_test.rb
git commit -m "feat: compare command — markdown and HTML reports with profile guard"
```

---

### Task 14: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# solid_queue benchmark

Benchmarks [solid_queue](https://github.com/rails/solid_queue) under realistic load, comparing the
official gem against a local fork. Produces traceable JSON results and comparison reports.

## Prerequisites

- [mise](https://mise.jdx.dev) (manages Ruby — nothing installed on the host OS)
- Docker (runs MySQL; nothing else is containerized)

## Setup

```sh
mise install
mise run setup
```

## Run a benchmark

```sh
# against the latest official gem
bin/bench run baseline --source upstream

# against a pinned release
bin/bench run baseline --source upstream@1.2.4

# against your local fork (must have a clean working tree, or pass --allow-dirty)
bin/bench run sprawl --source path:~/Projects/solid_queue
```

Each run: fresh MySQL volume → schema loaded **from the selected gem source** → solid_queue
supervisor forks workers → scenario enqueues load → waits for drain → writes
`results/<run-id>/result.json` (plus `logs/`). Every result is stamped with the resolved gem
version and git SHA.

## Scenarios

| Scenario | Params (`--set key=val`) | What it measures |
|---|---|---|
| `baseline` | `jobs=20000 rate=500 work_ms=50 duration=60` | Steady-state throughput/latency. `jobs=0` measures pure idle-polling DB cost for `duration` seconds. |
| `sprawl` | `seeds=100 fanout=50 depth=2 work_ms=10` | Fan-out burst: each job enqueues `fanout` children down to `depth`. Defaults total 255,100 jobs — trim with `--set` for quick runs. |

## Topology profiles

Profiles bundle MySQL resources + worker topology so comparisons stay apples-to-apples
(`profiles/*.yml`). Default: MySQL pinned to 1 CPU / 1 GB, 10 workers × 2 threads, 1 dispatcher —
small DB on purpose, so contention shows at laptop-friendly load.

```sh
bin/bench run baseline --profile ephemeral            # a committed profile
bin/bench run baseline --workers 50 --mysql-cpus 2    # ad-hoc override
```

`bench compare` refuses to compare runs with different resolved profiles unless you pass
`--force` — a gem-vs-gem delta should never secretly be a topology delta.

## Compare runs

```sh
bin/bench list
bin/bench compare results/<A>/result.json results/<B>/result.json
```

Writes `reports/<A>__vs__<B>/report.md` and `report.html` (delta tables, CPU/queue-depth
overlay charts, top statements by DB time).

## Repeatability

`--repeat 3` runs the scenario three times and prints the median throughput; all runs are kept.

## Metrics captured

- Throughput (jobs/sec + per-second series) and latency percentiles (enqueue→start, enqueue→finish)
- MySQL container CPU % (1 s samples via `docker stats`)
- Top 20 statements by total DB time (`performance_schema` digests, reset at scenario start)
- Queue depth series (ready / scheduled / claimed / blocked)

## Adding a scenario

1. Add defaults + expected-total lambda to `lib/bench/scenarios.rb`.
2. Add the enqueue branch to `harness/script/drive.rb` (and any new job class in `harness/app/jobs/`).
3. Params are automatically CLI-settable via `--set`.

## Development

```sh
mise run test    # orchestrator unit tests
mise run smoke   # tiny end-to-end run (~2 min)
```
```

- [ ] **Step 2: Verify README commands match reality**

Cross-check every command in the README against the implemented CLI (`bin/bench` usage output). Fix drift in whichever is wrong.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: concise usage README"
```

---

### Task 15: Final verification

- [ ] **Step 1: Full unit suite**

Run: `mise run test`
Expected: all green.

- [ ] **Step 2: Fresh-clone sanity** (simulates a teammate)

```bash
git clone . /tmp/sq-bench-clone && cd /tmp/sq-bench-clone
mise install && mise run setup && mise run smoke
```

Expected: smoke passes from a clean clone. Delete `/tmp/sq-bench-clone` after.

- [ ] **Step 3: Real comparison dry-run**

```bash
bin/bench run baseline --source upstream --profile default --set jobs=2000 --set rate=200
bin/bench run baseline --source path:~/Projects/solid_queue --profile default --set jobs=2000 --set rate=200
bin/bench compare results/<upstream>/result.json results/<fork>/result.json
```

Expected: both complete; report renders; numbers are plausible (non-zero CPU, latencies in ms range).

- [ ] **Step 4: Commit anything outstanding, then use superpowers:finishing-a-development-branch**

---

## Self-review notes (completed)

- **Spec coverage:** data flow (Task 10), fresh volume per run (Task 10 `mysql_fresh_start`), gem switching + dirty guard + per-source lockfiles (Tasks 2, 10), profiles + overrides + compare guard (Tasks 3, 13), bench_events instrumentation (Task 7), both v1 scenarios incl. idle variant (Tasks 5, 8), all six metric families (Tasks 6, 10), JSON results + logs + failed status (Tasks 9, 10), repeat (Task 11), compare md+html (Task 13), mise setup (Task 1), smoke test (Task 12), README (Task 14). Future scenarios slot in per README "Adding a scenario".
- **Known simplification:** `--repeat` reports median throughput only (all raw results kept); richer cross-run stats can come later. Sprawl `work_ms` defaults to 10 (spec silent); 255,100-job default total is spec-faithful but README warns to trim for quick runs.
- **Type consistency check:** `Profile#env` keys match `queue.yml`/`database.yml`/compose env consumption; `Scenario` fields match `Runner`/`drive.rb` usage; `Result` string-key access after `load` matches `Compare` usage (Result.load keeps string keys; Compare only reads loaded results — the compare test constructs Results with string-keyed hashes to mirror this).
