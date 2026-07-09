# Run Progress + ETA Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an updating `X/Y completed (P%) | ETA Mm Ss` status line while `bin/bench run` waits for a scenario's jobs to drain, instead of a silent terminal (spec: `docs/jeongri/specs/2026-07-09-run-progress-eta-design.md`).

**Architecture:** A new `Bench::ProgressReporter` class (`lib/bench/progress_reporter.rb`) with three stateless class methods (`format_duration`, `eta_seconds`, `format_line`) and a thin stateful instance (`#update`/`#finish`) that renders to an `IO`, redrawing in place on a TTY (`\r...\e[K`) or printing throttled plain lines otherwise. `Runner#wait_for_drain` (`lib/bench/runner.rb`) drives it once per existing 1s poll loop iteration — no new thread.

**Tech Stack:** Ruby 3.3 (mise), Minitest, stdlib only (no new gems).

**Conventions used throughout:**
- Repo root: `/home/luke/Projects/solid-queue-benchmark` — all paths below are relative to it.
- Run a single test file: `ruby -Ilib -Itest test/<file>.rb`
- Run the full suite: `mise run test` (equivalent to `ruby -Ilib -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'`)
- Commit after every task with the message given in the task.
- `DepthSampler` samples are hashes like `{"t" => <Float unix ts>, "ready" => Integer, "scheduled" => Integer, "claimed" => Integer, "blocked" => Integer, "failed" => Integer, "completed" => Integer}` (see `lib/bench/samplers.rb:56-106`). `ProgressReporter` only ever reads `"t"` and `"completed"`.

---

### Task 1: `ProgressReporter.format_duration`

**Files:**
- Create: `lib/bench/progress_reporter.rb`
- Test: `test/progress_reporter_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/progress_reporter_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: FAIL with `cannot load such file -- bench/progress_reporter` (LoadError)

- [ ] **Step 3: Write the minimal implementation**

Create `lib/bench/progress_reporter.rb`:

```ruby
# lib/bench/progress_reporter.rb
module Bench
  class ProgressReporter
    def self.format_duration(seconds)
      total = seconds.round
      hours, remainder = total.divmod(3600)
      minutes, secs = remainder.divmod(60)
      if hours.positive?
        format("%dh %dm %ds", hours, minutes, secs)
      elsif minutes.positive?
        format("%dm %ds", minutes, secs)
      else
        format("%ds", secs)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: `4 runs, 5 assertions, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Commit**

```bash
git add lib/bench/progress_reporter.rb test/progress_reporter_test.rb
git commit -m "feat: add ProgressReporter.format_duration"
```

---

### Task 2: `ProgressReporter.eta_seconds`

**Files:**
- Modify: `lib/bench/progress_reporter.rb`
- Modify: `test/progress_reporter_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/progress_reporter_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'eta_seconds' for Bench::ProgressReporter:Class`

- [ ] **Step 3: Write the minimal implementation**

Add to `lib/bench/progress_reporter.rb`, inside `class ProgressReporter`, after `format_duration`:

```ruby
    def self.eta_seconds(samples, expected_total, window: 12)
      return nil if samples.length < 2

      latest = samples.last
      reference = samples.reverse_each.find { |s| latest["t"] - s["t"] >= window } || samples.first

      dt = latest["t"] - reference["t"]
      dc = latest["completed"] - reference["completed"]
      return nil if dt <= 0 || dc <= 0

      remaining = expected_total - latest["completed"]
      return 0.0 if remaining <= 0

      remaining / (dc / dt)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: `9 runs, 13 assertions, 0 failures, 0 errors, 0 skips` (this Minitest version counts `assert_operator` as 2 assertions internally — `0 failures, 0 errors, 0 skips` is what matters)

- [ ] **Step 5: Commit**

```bash
git add lib/bench/progress_reporter.rb test/progress_reporter_test.rb
git commit -m "feat: add ProgressReporter.eta_seconds"
```

---

### Task 3: `ProgressReporter.format_line`

**Files:**
- Modify: `lib/bench/progress_reporter.rb`
- Modify: `test/progress_reporter_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/progress_reporter_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'format_line' for Bench::ProgressReporter:Class`

- [ ] **Step 3: Write the minimal implementation**

Add to `lib/bench/progress_reporter.rb`, after `eta_seconds`:

```ruby
    def self.format_line(completed, expected_total, eta_seconds)
      pct = expected_total.zero? ? 0.0 : (100.0 * completed / expected_total).round(1)
      eta_str = eta_seconds ? "ETA #{format_duration(eta_seconds)}" : "ETA calculating..."
      format("%d/%d completed (%.1f%%) | %s", completed, expected_total, pct, eta_str)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: `12 runs, 16 assertions, 0 failures, 0 errors, 0 skips` (this Minitest version counts `assert_operator`/`assert_includes`/`assert_match` as 2 assertions each internally — the exact number matters less than `0 failures, 0 errors, 0 skips`)

- [ ] **Step 5: Commit**

```bash
git add lib/bench/progress_reporter.rb test/progress_reporter_test.rb
git commit -m "feat: add ProgressReporter.format_line"
```

---

### Task 4: `ProgressReporter#update` / `#finish` (instance, TTY + non-TTY rendering)

**Files:**
- Modify: `lib/bench/progress_reporter.rb`
- Modify: `test/progress_reporter_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/progress_reporter_test.rb`:

```ruby
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
```

**Design note (added after Task 4's code-quality review):** `finish` originally took no arguments and only ever printed a bare newline in TTY mode — on non-TTY output, if a run completed within `plain_interval` seconds of the last printed line, the log would never show a final/100% line, undercutting the whole point of the non-TTY branch. `finish` is revised to accept optional final `samples` and force one last **unthrottled** line in non-TTY mode when given them, so piped/log output always ends with a definitive completion line.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'new' for Bench::ProgressReporter:Class` (no `initialize` defined yet)

- [ ] **Step 3: Write the minimal implementation**

Add to `lib/bench/progress_reporter.rb`, inside `class ProgressReporter`, before the `def self.format_duration` line:

```ruby
    def initialize(expected_total:, io: $stdout, window: 12, plain_interval: 10)
      @expected_total = expected_total
      @io = io
      @window = window
      @plain_interval = plain_interval
      @tty = io.respond_to?(:tty?) && io.tty?
      @last_plain_t = nil
    end

    def update(samples)
      return if samples.empty?

      line = render(samples)
      if @tty
        @io.print("\r#{line}\e[K")
      else
        t = samples.last["t"]
        return if @last_plain_t && (t - @last_plain_t) < @plain_interval
        @last_plain_t = t
        @io.puts(line)
      end
    end

    def finish(samples = nil)
      if @tty
        @io.print("\n")
      elsif samples && !samples.empty?
        @io.puts(render(samples))
      end
    end

    private

    def render(samples)
      latest = samples.last
      eta = self.class.eta_seconds(samples, @expected_total, window: @window)
      self.class.format_line(latest["completed"], @expected_total, eta)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby -Ilib -Itest test/progress_reporter_test.rb`
Expected: `18 runs, 35 assertions, 0 failures, 0 errors, 0 skips` (this Minitest version double-counts `assert_includes`/`assert_match` — `0 failures, 0 errors, 0 skips` is what matters)

- [ ] **Step 5: Commit**

```bash
git add lib/bench/progress_reporter.rb test/progress_reporter_test.rb
git commit -m "feat: add ProgressReporter#update and #finish"
```

---

### Task 5: Wire `ProgressReporter` into `Runner#wait_for_drain`

**Files:**
- Modify: `lib/bench/runner.rb:1-11` (require), `lib/bench/runner.rb:198-216` (`wait_for_drain`)

- [ ] **Step 1: Add the require**

In `lib/bench/runner.rb`, the require block currently reads:

```ruby
require "json"
require "fileutils"
require "time"
require "bench/shell"
require "bench/mysql_client"
require "bench/digests"
require "bench/samplers"
require "bench/stats"
require "bench/result"
```

Add `require "bench/progress_reporter"` after `require "bench/samplers"`:

```ruby
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
```

- [ ] **Step 2: Rewrite `wait_for_drain`**

Replace the existing `wait_for_drain` method:

```ruby
    def wait_for_drain(depth_sampler)
      return if @scenario.expected_total.zero?
      deadline = Time.now + @timeout
      loop do
        snap = depth_sampler.latest
        if snap && snap["failed"].positive?
          raise RunFailure, "#{snap["failed"]} job(s) failed during the run (see solid_queue_failed_executions)"
        end
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
```

with:

```ruby
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
```

`reporter.finish(depth_sampler.samples)` passes the full sample history so non-TTY output gets one last unthrottled line reflecting the true final state, whether the drain succeeded, a job failed, or it timed out (see Task 4's revised `finish`).

- [ ] **Step 3: Run the full test suite to confirm nothing broke**

Run: `mise run test`
Expected: all tests pass, no failures or errors (existing suite plus the `ProgressReporter` tests)

- [ ] **Step 4: Commit**

```bash
git add lib/bench/runner.rb
git commit -m "feat: show progress and ETA while a benchmark run drains"
```

---

### Task 6: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run a short real benchmark and observe the progress line**

Run: `bin/bench run baseline --source upstream --profile smoke --set jobs=200 --set rate=100 --set work_ms=0 --timeout 120`

Expected: after the `== run 1/1: ...` header, a single line appears that updates in place (no scrolling) showing `N/200 completed (P%) | ETA ...`, ending with `completed: <path to results/.../result.json>` on its own line once the run finishes.

- [ ] **Step 2: Confirm non-TTY output stays clean**

Run: `bin/bench run baseline --source upstream --profile smoke --set jobs=200 --set rate=100 --set work_ms=0 --timeout 120 | cat`

Expected: progress appears as a handful of discrete plain-text lines (roughly one every 10s), not a single line littered with `\r`/`\e[K` control sequences.

No commit for this task — it's a manual smoke check, not a code change.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-09-run-progress-eta.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
