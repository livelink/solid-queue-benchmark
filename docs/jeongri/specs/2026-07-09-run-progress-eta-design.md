# Design: Inline progress + ETA for `bin/bench run`

## Problem

`bin/bench run` prints a header line (`== run 1/1: sprawl | upstream | profile default ...`)
and then goes silent until the run finishes — often several minutes later, with no indication
of progress. Nearly all of that wall-clock time is spent in `Runner#wait_for_drain`, waiting
for the job queue to drain to `scenario.expected_total` completed jobs.

## Goal

While a run is draining, show an updating status line with completed/expected count, percent,
and an ETA, e.g.:

```
1,234/5,000 completed (24.7%) | ETA 5m 30s
```

## Scope

Progress reporting covers **`Runner#wait_for_drain` only** — the phase where we have a real
completion target (`scenario.expected_total`) and real progress data (`DepthSampler` samples).
Earlier setup phases (source prep, mysql restart, db setup, waiting for worker processes) are
comparatively quick and have no meaningful "percent done" to report; they are out of scope and
remain silent, as today.

## Architecture

### New class: `Bench::ProgressReporter` (`lib/bench/progress_reporter.rb`)

`Runner#wait_for_drain` already loops every 1s, calling `depth_sampler.latest`. That loop gains
one more call per iteration: `reporter.update(depth_sampler.samples)`. No new thread or polling
is introduced — the reporter is driven by the existing loop and reads the existing sample
history that `DepthSampler` already accumulates (`{"t" => <float ts>, "completed" => <int>, ...}`
per sample, see `lib/bench/samplers.rb`).

```ruby
class ProgressReporter
  def initialize(expected_total:, io: $stdout, window: 12, plain_interval: 10)
  def update(samples)   # render current state; no-op if samples is empty
  def finish            # print trailing newline if TTY; no-op otherwise
end
```

**Rendering modes**, chosen once at construction via `io.respond_to?(:tty?) && io.tty?`:

- **TTY**: redraw the line in place — `io.print("\r#{line}\e[K")` (no trailing newline). `\e[K`
  clears to end of line so a shorter line doesn't leave stale characters from a longer one.
- **non-TTY** (piped output, CI logs, redirected to a file): print the line with a trailing
  newline via `io.puts(line)`, throttled to at most once per `plain_interval` seconds (default
  10s), so log files get periodic progress without carriage-return control characters or a
  flood of near-identical lines.

`finish` prints a bare newline (TTY mode only) so whatever prints next — `completed: <path>`,
an error message, or the next repeat's `== run i/N` header — starts on a clean line.

### ETA calculation

Uses a **trailing window** (default 12s) of samples rather than the overall average, so it
reacts to throughput changes mid-run:

1. Take the latest sample (`t_now`, `completed_now`).
2. Walk backward through `samples` to find the oldest sample within `window` seconds of `t_now`
   (or the first sample, if the run hasn't been going that long yet).
3. `rate = (completed_now - completed_then) / (t_now - t_then)`.
4. `eta_seconds = (expected_total - completed_now) / rate`.
5. If there isn't enough data yet (fewer than 2 samples, or `dt <= 0`, or `rate <= 0`), ETA is
   unknown — render `ETA calculating...` instead of a bogus value.
6. If `completed_now >= expected_total`, ETA is `0`.

### Pure/stateless helpers (class methods, unit-testable without I/O)

Following the existing convention of `Bench::CpuSampler.parse_cpu_pct` — stateless parsing pulled
out to a class method so it's testable without spinning up threads or real I/O:

- `ProgressReporter.eta_seconds(samples, expected_total, window:)` → `Float` or `nil`
- `ProgressReporter.format_duration(seconds)` → `"5m 30s"` / `"1h 2m 3s"` / `"45s"`
- `ProgressReporter.format_line(completed, expected_total, eta_seconds)` → the full status string

The instance (`#update`/`#finish`) is a thin I/O/throttling wrapper around these.

### Integration point

`lib/bench/runner.rb`, `#wait_for_drain`:

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
    reporter.finish
  end
end
```

`reporter.finish` in the `ensure` guarantees the terminal is left on a clean line on every exit
path: normal completion, job failure, or timeout.

## Pattern fit

- One class per file under `lib/bench/`, matching every other module in the project.
- No new dependency — `Gemfile` has no TTY/progress-bar gem (no `tty-*`, `ruby-progressbar`),
  and none is needed; `IO#tty?`, `IO#print`, and `\e[K` are stdlib/ANSI-standard.
- Stateless class methods for testable logic mirrors `CpuSampler.parse_cpu_pct`.
- The TTY-vs-plain-fallback split is new territory for this codebase (nothing here does this
  today), but it's the minimal standard approach for keeping piped/log output clean — no
  existing in-repo pattern was available to conform to.

## Edge cases

- `scenario.expected_total == 0` (baseline's idle/duration-only variant): `wait_for_drain`
  already returns before creating a reporter — unchanged behavior, no progress line.
- Job failure or drain timeout: `reporter.finish` runs (via `ensure`) before the `RunFailure` is
  raised, so `RUN FAILED: ...` (printed by `Runner#call`'s rescue) lands on its own line.
- `--repeat N`: each repeat constructs a new `Runner` and thus a new `ProgressReporter` inside
  `wait_for_drain`; each drain phase's line is finished (newline) before the next repeat's
  `== run i/N` header prints.
- Empty/no samples yet when `update` is first called: no-op rather than crashing on `nil`.

## Testing

New `test/progress_reporter_test.rb` (Minitest, no mocking library — matches existing style):

- `format_duration`: `0` → `"0s"`, `45` → `"45s"`, `90` → `"1m 30s"`, `3661` → `"1h 1m 1s"`.
- `eta_seconds`: steady-rate synthetic samples → expected seconds within a delta; accelerating
  rate → reflects the recent window, not the overall average; fewer than 2 samples → `nil`;
  zero/negative rate → `nil`; `completed >= expected_total` → `0`.
- `format_line`: renders `"completed/expected"`, percent, and either the ETA string or
  `"ETA calculating..."`.
- `#update` with a `StringIO` (non-TTY): asserts a plain line with newline is written, and that
  a second call within `plain_interval` seconds does not write again (throttling) — inject a
  fake clock or pass explicit timestamps rather than sleeping in the test.
- `#update` with a fake IO object (`tty?` stubbed `true`, capturing `print` calls): asserts
  `\r`-prefixed, `\e[K`-suffixed, no-newline output on every call (no throttling in TTY mode).
- `#finish`: writes a bare newline in TTY mode, no-op in non-TTY mode.

No changes to `Runner`'s existing tests — `Runner` itself has no dedicated unit tests today (it's
the integration-style orchestrator); the new reporter's wiring is covered by the class-level
tests above plus a manual run to visually confirm the line updates as expected.
