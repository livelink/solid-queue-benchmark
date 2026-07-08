# Solid Queue Benchmark Suite — Design

**Date:** 2026-07-08
**Status:** Approved for planning

## Purpose

Produce trustworthy, presentation-ready performance figures for `solid_queue`, comparing the official gem against a local fork (`~/Projects/solid_queue`, MrLukeSmith/solid_queue). Motivating problems observed at scale:

- Excessive CPU consumption on the database (MySQL) side.
- Underwhelming performance of the `limits_concurrency` primitive, which upstream discourages in favor of per-queue limits — conflicting with the intended integration pattern (wildcard queues + `priority` for processing hierarchy).

The suite must make fork-vs-upstream deltas attributable to the gem change alone, with results traceable to exact commits, suitable for validating adoption decisions.

## Scope

**v1 scenarios:** `baseline` (steady-state) and `sprawl` (job fan-out). The scenario abstraction must be pluggable so `limits_concurrency` stress and priority-hierarchy scenarios can be added later without harness changes.

**Metrics:** throughput & latency percentiles, MySQL CPU/load, query-level statement stats, queue-depth over time. Concurrency-limit metrics (semaphore waits, blocked-execution depth, time-to-unblock) are designed-for but land with the future scenario.

## Architecture (chosen approach)

Minimal Rails harness + locally forked workers, MySQL in Docker. Rejected alternatives: fully containerized workers (Docker VM scheduling noise on macOS pollutes latency numbers; image rebuild per fork edit) and a bare ActiveJob harness (fights solid_queue's Rails/railties assumptions).

```
solid-queue-benchmark/
├── README.md              # concise usage doc (see Deliverables)
├── mise.toml              # ruby pin + task wrappers; no host-OS installs
├── bin/bench              # orchestrator CLI: run, compare, list
├── docker-compose.yml     # MySQL 8.0, cpus/memory pinned from profile
├── Gemfile                # solid_queue source resolved from SOLID_QUEUE_SOURCE
├── harness/               # minimal Rails app (no web server)
│   ├── config/            #   database.yml, queue.yml generated from profile
│   ├── app/jobs/          #   benchmark job classes
│   └── db/                #   solid_queue schema + bench_events table
├── profiles/              # topology profiles (default.yml, ephemeral.yml, …)
├── scenarios/             # one file per scenario
├── results/               # timestamped JSON per run (git-ignored)
└── reports/               # generated comparison reports
```

### Run data flow

`bin/bench run sprawl --source path:~/Projects/solid_queue [--profile default]`

1. Resolve gem source; bundle with a per-source lockfile; record resolved version + git SHA.
2. Start MySQL via Docker Compose with a **fresh volume every run** (cold, deterministic state), cpus/memory pinned from the profile; load schema.
3. Snapshot `performance_schema` statement digests; start a 1 s `docker stats` CPU sampler and a 1 s queue-depth sampler (ready/claimed/scheduled counts).
4. Boot the solid_queue supervisor: forks `workers.count` worker processes × `workers.threads` threads on `queues: "*"`, plus a dedicated dispatcher/scheduler process (mirrors production's dedicated scheduling pod).
5. Scenario driver enqueues load per scenario definition; waits for drain or timeout.
6. Tear down; diff digest snapshots; aggregate `bench_events`; write one timestamped JSON result file.

### Job instrumentation

Every benchmark job records enqueued/started/finished timestamps to a `bench_events` table via ActiveJob callbacks. Latency percentiles derive from this table. Cost is one extra insert per job in the same MySQL — identical across gem sources, so it cancels in comparisons.

## Topology profiles

Topology is a profile, not a constant. A profile bundles the knobs that must move together for comparability:

```yaml
# profiles/default.yml
mysql:
  cpus: 1.0        # deliberately small so contention shows at light load
  memory: 1g
workers:
  count: 10        # worker processes, each polling queues: "*"
  threads: 2
dispatcher:
  count: 1
```

- **Baseline rationale:** MySQL at 1 CPU / 1 GB with 10 workers × 2 threads preserves the production pressure ratio (many pollers per DB core) while surfacing pathology in minutes on a laptop. Production-like shape (e.g. 50×2) lives in `profiles/ephemeral.yml` for occasional full-scale validation.
- **Overrides:** `--profile <name>` or ad-hoc flags (`--workers 50 --mysql-cpus 2`).
- **Comparison guard:** every result JSON embeds the full resolved profile; `bench compare` refuses to compare runs with differing profiles unless `--force` is passed. A fork-vs-upstream delta can never secretly be a topology delta.

## Gem source switching

`SOLID_QUEUE_SOURCE` accepts:

- `upstream@<version>` — RubyGems release (e.g. `upstream@1.2.4`)
- `path:<dir>` — local fork checkout

The Gemfile branches on the env var; each distinct source keeps its own lockfile so switching is instant and doesn't churn a shared `Gemfile.lock`. For `path:` sources the run **refuses to start if the fork's working tree is dirty** unless `--allow-dirty` is passed; dirty runs are stamped `sha+dirty` in the result JSON. Every result is stamped with the resolved version/SHA so presented numbers are traceable to exact commits.

## Scenarios

Scenarios are small Ruby classes with declared, CLI-overridable parameters; all parameters are recorded in the result JSON.

- **`baseline`** — enqueue N trivial jobs (default 20,000) at steady rate R (default 500/sec), each simulating work via sleep (default 50 ms; 0 is valid to isolate queue overhead). Variant: **zero jobs for 60 s** to measure pure idle-polling DB cost.
- **`sprawl`** — S seed jobs (default 100), each enqueuing F children (default 50), recursive to depth D (default 2), children with mixed priorities. Measures enqueue contention during simultaneous dequeue, latency degradation during the burst, and time-to-drain.

Future (out of v1, must slot in without harness changes): `limits_concurrency` stress (shared concurrency keys at varying cardinality/limits), priority hierarchy on wildcard queues.

## Metrics per run

| Metric | Source |
|---|---|
| Throughput (jobs/sec, overall + time series) | `bench_events` |
| Latency p50/p95/p99 (enqueue→start, enqueue→finish) | `bench_events` |
| MySQL CPU % (avg/max, time series) | `docker stats` sampler |
| Per-statement DB cost (executions, total latency, rows examined) attributed to solid_queue internals | `performance_schema` digest diff |
| Queue depth over time (ready/claimed/scheduled) | 1 s sampler on solid_queue tables |
| Run metadata (gem source + SHA, scenario params, resolved profile, timings) | orchestrator |

## Output & comparison

- Each run writes one timestamped JSON result file under `results/`.
- `bin/bench compare results/A.json results/B.json` renders a markdown report (delta tables with % change) plus an HTML version with charts (latency distributions, CPU-over-time overlays, top-10 statement digests side by side).
- `--repeat 3` runs a scenario multiple times, reporting per-run numbers plus median, so variance is visible.

## Local setup (mise)

No host-OS installs. `mise.toml` pins Ruby; `mise install` plus a working Docker daemon is the full setup. Common entry points are mise tasks (`setup`, `bench`) wrapping `bin/bench`, which remains a plain Ruby script callable directly (CI, teammates without mise).

## Failure handling

- Fail-fast: supervisor death, worker crashes, or drain timeout mark the run `failed` in the JSON with logs preserved under `results/<run>/logs/`. Partial numbers are never reported as complete.
- Smoke test: a tiny scenario (100 jobs, 2 workers) verifies the pipeline end-to-end before trusting large runs.

## Deliverables

1. The harness, orchestrator, profiles, and two v1 scenarios as above.
2. **README.md** — concise usage documentation covering: prerequisites (mise + Docker), setup, running a benchmark, switching gem source (`SOLID_QUEUE_SOURCE` forms), profiles and overriding topology/MySQL resources, comparing runs, and adding a new scenario. To the point; the spec holds the rationale, the README holds the how-to.
