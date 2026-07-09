# Project Context

Last verified: 2026-07-09
Last verified SHA: 311d7dcae9bb6a950120c765bd985b78f259f6cc

## Test Framework & Patterns

Minitest (`minitest/autorun`), no RSpec, no mocking library. Tests live in `test/*_test.rb`,
one file per `lib/bench/*.rb` module, named `<module>_test.rb`. Style is mostly real-object,
integration-ish tests (e.g. `ShellTest` actually shells out to `echo`/`ruby -e`), plus focused
unit tests for pure parsing/formatting logic exposed as class methods (e.g.
`Bench::CpuSampler.parse_cpu_pct` is tested directly with raw sample strings). `CliTest` calls
`Bench::CLI.parse_run_options` directly to assert on the parsed options hash. Run via `rake`
(see `Rakefile`/`npm run test` equivalent — check `Gemfile`/`mise.toml` for the exact task; README
documents `bin/rake` or similar).

## Architecture & Conventions

CLI entrypoint: `bin/bench` → `Bench::CLI.start(argv)` (`lib/bench/cli.rb`), a `module_function`
module (no instance state), dispatching on subcommand string (`run`, `list`, `setup`, `compare`).

`CLI.run` builds a `Scenario`, `SourceSpec`, and `Profile`, then loops `opts[:repeat]` times
constructing a fresh `Bench::Runner` and calling `.call`. Only output before/after a run today:
a single `puts "== run i/N: ..."` line before, and `Runner#call`'s own `puts "#{status}: #{path}"`
after — nothing printed while a run is in progress.

`Bench::Runner#call` (`lib/bench/runner.rb`) is the actual orchestrator for one run, entirely
synchronous/blocking, structured as ordered private steps: `prepare_source` → `mysql_fresh_start`
→ `db_setup` → `start_supervisor` → `wait_for_processes` → (start `CpuSampler`/`DepthSampler`) →
`run_driver` → `wait_for_drain` → build metrics → `result.write`. Almost all wall-clock time for
a typical run is spent in `wait_for_drain`, which polls `DepthSampler#latest` every 1s in a
`sleep 1` loop until `completed >= scenario.expected_total` (or times out per `--timeout`).

`DepthSampler` (`lib/bench/samplers.rb`) runs its own background `Thread`, polling MySQL every
`interval` (default 1.0s) and appending a hash sample (`ready/scheduled/claimed/blocked/failed/
completed`) to `@samples`; `#latest` returns the most recent sample. `CpuSampler` similarly
threads `docker stats` output. Both use plain `puts`/`warn` for any output elsewhere in the
codebase — there is no existing progress-bar, spinner, or ANSI cursor-control code authored by
this project (the only ANSI handling is *stripping* Docker's own codes in `CpuSampler.parse_cpu_pct`).

`Scenario` objects (`lib/bench/scenarios.rb`) expose `expected_total` — the known job count a
run should complete — already used by `wait_for_drain` as the completion target.

Small, flat `lib/bench/*.rb` modules/classes, one per file, no nested namespacing beyond `Bench::`.
Private methods grouped under `# --- section ---` comments inside classes (see `Runner`).

## Naming Conventions

Snake_case files matching the primary class/module (`runner.rb` → `Bench::Runner`). Test files
`<name>_test.rb` mirroring `lib/bench/<name>.rb`. Class methods for pure/stateless logic
(`self.parse_cpu_pct`) even inside otherwise-instance classes, specifically so they're testable
without spinning up threads/IO.

## Key Dependencies

Plain Ruby stdlib (`optparse`, `json`, `fileutils`, `time`) — no CLI/UI gem (no `tty-*`,
`ruby-progressbar`, etc. in `Gemfile`). Docker Compose for MySQL. Rails app under `harness/` is
the actual Solid Queue workload driver, shelled out to via `Bench::Shell`.
