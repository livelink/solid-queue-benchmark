# Postgres Support Design

## Purpose

The benchmark tool currently only supports MySQL as the backing database. This adds
Postgres as a second, selectable engine so a run can target either database and results
from both can be compared like-for-like via `bin/bench compare`.

## Goals

- A run picks its engine via a new `--database mysql|postgres` flag (default `mysql`,
  preserving current behavior for existing callers).
- Postgres runs produce the same metrics as MySQL runs, including a top-statements
  digest equivalent (via `pg_stat_statements`), so comparisons are apples-to-apples.
- Resource-limit naming (CLI flags, env vars, profile keys, result metric keys) becomes
  engine-neutral, since only one engine runs per run and the same profile/topology
  should be usable against either engine.
- `bin/bench compare` can compare a MySQL run against a Postgres run and clearly shows
  which engine each side used, without treating the engine difference as a profile
  mismatch (comparing engines is the point of this feature).

## Non-goals

- No migration path for old `result.json` files using the pre-rename field names
  (`mysql_cpus`, `mysql_cpu`). Comparing an old result against a new one will show blank
  values for the renamed fields.
- No support for running both engines simultaneously in one run.
- No `Runner` unit tests are added — `Runner` has none today (it's the integration
  orchestrator, exercised via `mise run smoke`); this is unchanged.

## Architecture

### New files

**`lib/bench/engines.rb`** — `Bench::Engines::REGISTRY`, a hash keyed by `"mysql"` and
`"postgres"`. Each entry holds the facts specific to that engine:

- `client_class` — `Bench::MysqlClient` or `Bench::PostgresClient`
- `container` — docker container name for `CpuSampler` (`sq-bench-mysql` /
  `sq-bench-postgres`)
- `service` — docker-compose service name to bring up (`mysql` / `postgres`)
- `port_env` / `default_port` — host port env var and fallback (`BENCH_MYSQL_PORT` /
  `13306`, `BENCH_POSTGRES_PORT` / `15432`)
- `digest_reset_sql` / `digest_fetch_sql` — engine-specific SQL for `Digests`

`Bench::Engines.fetch(name)` returns the entry or raises `ArgumentError` for an unknown
engine name. `Bench::Engines.names` lists valid engine names, used by CLI validation and
usage text.

This is a new pattern (no comparable lookup table exists elsewhere in the codebase), and
it's the one deliberate structural addition of this design. It's justified because five
independent call sites — `Runner` (client/container/service/port), `CLI#setup` (image
pull), `CpuSampler` (container name), `Digests` (SQL), and `database.yml` (adapter) — all
need the same small set of per-engine facts. Without a single source of truth, each would
carry its own `if engine == "postgres"` branch, and adding a third engine later would mean
finding and updating all of them.

**`lib/bench/postgres_client.rb`** — `Bench::PostgresClient`, mirroring the existing
`Bench::MysqlClient` exactly:

```ruby
BASE_CMD = %w[docker compose exec -T postgres psql -U bench -d bench -tA -F] + ["\t", "-c"]
```

Same `#query`/`#scalar` interface, same TSV-split-by-newline-then-tab parsing. No new
pattern — this follows `MysqlClient` precisely.

### Changed files

**`docker-compose.yml`** — add a `postgres` service:

```yaml
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

The existing `mysql` service's `cpus`/`mem_limit` switch from `BENCH_MYSQL_CPUS`/
`BENCH_MYSQL_MEMORY` to the shared `BENCH_DB_CPUS`/`BENCH_DB_MEMORY`, since only one
engine's container runs per run and the same resource-limit flag should apply to
whichever one is active.

Only the selected service is started per run (`docker compose up -d --wait <service>`,
via `Engines.fetch(database).service`) — the other engine's container is never brought
up, so resource-limit comparability isn't affected by an idle second container.
`docker compose down -v` (teardown) is unaffected — it already tears down all services
regardless of which one was started.

**`harness/config/database.yml`** — branches on `ENV.fetch("BENCH_DATABASE", "mysql")`:

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

`Runner` adds `BENCH_DATABASE` to the harness process env (`base_env`) so this resolves
to the engine the run actually selected.

**`Gemfile`** — add `gem "pg"` unconditionally, alongside the existing unconditional
`gem "trilogy"`. Both adapter gems are always bundled; which one is actually used is
determined at runtime by `database.yml`.

Unlike `trilogy` (pure Ruby), `pg` has a native extension that links against `libpq` at
`bundle install` time. `Runner#prepare_source` runs `bundle install`/`check` on the host
(via `Shell.capture`, not inside a container), so the host needs `libpq` dev headers
(e.g. `libpq-dev` on Debian/Ubuntu, `postgresql` via Homebrew on macOS) installed before
`mise run setup` or any `bin/bench` run — this is a new host prerequisite, not just a
Docker image, and must be called out in `README.md`'s prerequisites section alongside
the existing Docker/mise ones.

**`harness/script/db_setup.rb`** — branches on
`ActiveRecord::Base.connection.adapter_name`:

- MySQL (`"Trilogy"`): unchanged — `CREATE DATABASE IF NOT EXISTS` (idempotent,
  belt-and-suspenders alongside `MYSQL_DATABASE` auto-creation).
- Postgres (`"PostgreSQL"`): skip the `CREATE DATABASE` step (Postgres doesn't support
  `IF NOT EXISTS` on `CREATE DATABASE`, and `POSTGRES_DB` already auto-creates it), and
  instead run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` (idempotent, needed for
  the digest metric).

**`lib/bench/profile.rb`** and **`profiles/*.yml`** — rename `mysql_cpus`/`mysql_memory`
attributes to `db_cpus`/`db_memory`; env keys `BENCH_MYSQL_CPUS`/`BENCH_MYSQL_MEMORY` to
`BENCH_DB_CPUS`/`BENCH_DB_MEMORY`; YAML `mysql:` section key to `db:`. `Profile` itself
stays engine-agnostic — it only ever describes topology + resource limits for whichever
engine the run selects, not the engine itself.

**`lib/bench/digests.rb`** — constructor takes `reset_sql:` and `fetch_sql:` instead of
the current hardcoded `FETCH_SQL` constant and hardcoded `TRUNCATE
performance_schema...` in `#reset`. `#fetch`'s column mapping (`digest_text, count,
total_ms, rows_examined`) is unchanged and stays engine-agnostic — both engines' SQL is
written to project columns in that order:

- MySQL fetch SQL: unchanged (`performance_schema.events_statements_summary_by_digest`).
- MySQL reset SQL: unchanged (`TRUNCATE performance_schema...`).
- Postgres fetch SQL: `SELECT query, calls, ROUND(total_exec_time, 1), rows FROM
  pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'bench')
  ORDER BY total_exec_time DESC LIMIT 20` (Postgres's `total_exec_time` is already in
  milliseconds, unlike MySQL's picosecond `SUM_TIMER_WAIT` (hence the existing `/1e9`
  conversion in the MySQL fetch SQL), but `Digests` doesn't care about units — it just
  maps columns positionally).
- Postgres reset SQL: `SELECT pg_stat_statements_reset()`.

This is a minor generalization of an existing class, not a new pattern — `Digests`
already took its SQL execution client as a constructor arg; now its SQL text is also
supplied by the caller instead of hardcoded.

**`lib/bench/runner.rb`**:

- Constructor takes `database:` (engine name string). Resolves
  `@engine = Engines.fetch(database)` once and uses it everywhere the class currently
  hardcodes MySQL:
  - `@db = @engine.client_class.new` (replaces `@mysql`)
  - `CpuSampler.new(container: @engine.container)`
  - `DepthSampler.new(client: @engine.client_class.new)`
  - `Digests.new(client: @db, reset_sql: @engine.digest_reset_sql, fetch_sql:
    @engine.digest_fetch_sql)`
  - `compose_env` merges `@engine.port_env => db_port` (replaces the hardcoded
    `BENCH_MYSQL_PORT` merge)
  - `db_port` (renamed from `mysql_port`) reads `ENV.fetch(@engine.port_env,
    @engine.default_port.to_s)`
  - `db_fresh_start` (renamed from `mysql_fresh_start`) runs
    `docker compose up -d --wait #{@engine.service}` — only the selected service
  - `base_env` gains `"BENCH_DATABASE" => database`
- `run_id` includes the engine: `"#{started_at...}-#{scenario.name}-#{database}-#{source.key}"`,
  so `bin/bench list` and the results directory disambiguate at a glance.
- `Result` gains a `database:` field, set to the engine name.
- `#build_metrics`'s latency query currently depends on MySQL-only SQL functions
  (`TIMESTAMPDIFF(MICROSECOND, ...)`, `UNIX_TIMESTAMP(...)`). No single SQL expression is
  portable across `trilogy` and `pg` output formatting for this, so instead:
  - Fetch raw columns: `SELECT enqueued_at, started_at, finished_at FROM bench_events`
    (portable — plain column selection, no engine-specific functions).
  - Diff timestamps in Ruby via `Time.parse` on each returned string, computing
    millisecond diffs and Unix timestamps the same way for both engines.

  This is a new pattern for this one method (previously pure SQL, now partly computed in
  Ruby) — justified because avoiding it would mean maintaining two divergent SQL strings
  for a query that runs exactly once, at the end of a run, well outside any hot path.
- `mysql_cpu` metrics key renamed to `db_cpu` in `#build_metrics`'s returned hash.

**`lib/bench/cli.rb`**:

- New `--database ENGINE` option, default `"mysql"`. `parse_run_options` validates it
  against `Engines.names`, raising `ArgumentError` for anything else (same style as the
  existing scenario/source validation).
- `--mysql-cpus`/`--mysql-memory` flags renamed to `--db-cpus`/`--db-memory`.
- `run`'s per-iteration header line includes the engine name, and its
  `profile.mysql_cpus`/hardcoded `"mysql"` reference (`CLI.run`, currently
  `" (#{profile.workers}w x #{profile.threads}t, mysql #{profile.mysql_cpus}cpu)"`)
  updates to `profile.db_cpus` and the selected engine name instead of the literal
  string `"mysql"`.
- `list`'s per-result CPU column (currently `metrics.dig("mysql_cpu", "avg_pct")`)
  updates to `metrics.dig("db_cpu", "avg_pct")` — otherwise it silently reads a key that
  no longer exists in new result files and always prints `-` with no error.
- `setup` pulls both images unconditionally: `docker compose pull mysql postgres`.
- Usage text documents `--database mysql|postgres`.

**`lib/bench/result.rb`** — `FIELDS` gains `:database`.

**`lib/bench/compare.rb`**:

- Adds a "Database" row to both the markdown and HTML comparison tables (alongside
  Run/Source/Scenario/Profile), showing each side's engine. This is purely informational
  — it is not part of `check_profiles!`'s mismatch guard, since comparing two different
  engines under the same profile is exactly what this feature exists to do.
- `mysql_cpu` → `db_cpu` in `METRIC_ROWS` and the SVG chart data key; row label "MySQL CPU
  avg (%)" → "DB CPU avg (%)", chart title "MySQL CPU %" → "DB CPU %".

**`README.md`** — documents the `--database` flag, lists Postgres as a second
prerequisite (Docker image, pulled automatically by `setup`, plus the host `libpq` dev
headers noted above), and updates the metrics section for the renamed fields. This
includes correcting the existing MySQL-only prerequisite/architecture lines ("Docker for
MySQL 8.0", "Workers run on the host. Only MySQL is containerized.") rather than just
adding a Postgres bullet alongside them.

**`mise.toml`** — the `setup` task's description ("Install gems for the default
(upstream) source and pull the MySQL image") updates to reflect that it now pulls both
images.

## Error handling

- An invalid `--database` value raises `ArgumentError`, caught by `CLI.start`'s existing
  `rescue ArgumentError` → `warn "error: ..."` + `exit 1`. Same path as an invalid
  `--source` or unknown scenario today.
- Postgres readiness is gated the same way MySQL's is: the `postgres` service has a
  `pg_isready` healthcheck, and `docker compose up -d --wait` blocks on it, reusing
  existing timeout/retry semantics — no new polling logic.
- `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` is idempotent and safe to run on
  every fresh container.
- Any Postgres-specific setup failure (missing extension, connection failure, etc.)
  surfaces through `Runner#call`'s existing `rescue StandardError => e` →
  `result.error` / `RunFailure` path — the same failure reporting used for any other
  setup failure today. No new error-handling path is introduced.

## Testing

- **`test/postgres_client_test.rb`** (new) — mirrors `test/mysql_client_test.rb`: asserts
  the `psql` command shape via a fake `runner:`, TSV-row parsing (`test_query_parses_tsv_rows`),
  and `scalar` returning nil on empty output (`test_scalar_nil_on_empty`).
- **`test/engines_test.rb`** (new) — asserts `Engines::REGISTRY` has `"mysql"` and
  `"postgres"` entries with the expected `client_class`/`container`/`service` values;
  `Engines.fetch("bogus")` raises `ArgumentError`; `Engines.names` returns exactly
  `["mysql", "postgres"]`.
- **`test/digests_test.rb`** — extend the existing `FakeClient`-based test to pass
  explicit `reset_sql:`/`fetch_sql:` into `Digests.new` and confirm `#fetch` still maps
  columns correctly, proving the class no longer assumes MySQL-only SQL text.
- **`test/profile_test.rb`** — update `test_loads_default_profile_by_name`,
  `test_cli_overrides_win`, and `test_env_map` assertions from `mysql_cpus`/`mysql_memory`
  to `db_cpus`/`db_memory`, and from `BENCH_MYSQL_CPUS`/`BENCH_MYSQL_MEMORY` to
  `BENCH_DB_CPUS`/`BENCH_DB_MEMORY`.
- **`test/cli_test.rb`** — add a case parsing `--database postgres` into
  `opts[:database]`, and a case asserting an unrecognized `--database` value raises
  `ArgumentError` (same style as `test_run_requires_scenario_and_source`).
- **`test/compare_test.rb`** — update the `result` fixture: `profile` hash uses
  `db_cpus`, `metrics` uses `db_cpu`, and a `database` field is added; add an assertion
  that `render_markdown`/`render_html` output includes a "Database" row and the "DB CPU"
  label.
- **`test/samplers_test.rb`** — no changes needed; `CpuSampler` already takes
  `container:` as a parameter.
- **Manual verification** — `Runner` has no unit tests today (it's the integration
  orchestrator, exercised via `mise run smoke`); this is unchanged. Once implemented,
  verify manually with something like
  `bin/bench run baseline --database postgres --profile smoke --set jobs=100 --set rate=100 --set work_ms=0 --timeout 180`,
  the Postgres equivalent of the existing `mise run smoke` task, and a
  `bin/bench compare` between a MySQL and a Postgres result.
