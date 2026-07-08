# solid_queue benchmark

Benchmarks [solid_queue](https://github.com/rails/solid_queue) under realistic load, comparing the
official gem against a local fork. It writes traceable JSON results and markdown/HTML comparison
reports.

## Prerequisites

- [mise](https://mise.jdx.dev) for the pinned Ruby version
- Docker for MySQL 8.0

Workers run on the host. Only MySQL is containerized.

## Setup

```sh
mise install
mise run setup
```

If mise reports that `mise.toml` is not trusted, run `mise trust` once in the checkout, then retry.

`setup` bundles the default upstream source and pulls the MySQL image.

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

## Scenarios

| Scenario | Params (`--set key=val`) | Measures |
|---|---|---|
| `baseline` | `jobs=20000 rate=500 work_ms=50 duration=60` | Steady-state throughput and latency. `jobs=0` measures idle polling for `duration` seconds. |
| `sprawl` | `seeds=100 fanout=50 depth=2 work_ms=10` | Fan-out burst where each job enqueues `fanout` children down to `depth`. Defaults total 255,100 jobs; reduce params for quick runs. |

Examples:

```sh
bin/bench run baseline --source upstream --profile smoke --set jobs=100 --set rate=100 --set work_ms=0 --timeout 180
bin/bench run sprawl --source path:~/Projects/solid_queue --set seeds=5 --set fanout=10 --set depth=1
```

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

## Compare Runs

```sh
bin/bench list
bin/bench compare results/<A>/result.json results/<B>/result.json
```

Reports are written to `reports/<A>__vs__<B>/report.md` and `report.html`. They include metric
deltas, MySQL CPU and ready-depth overlay charts, and top SQL statements by total database time.

Use `--force` only when you intentionally want to compare different profiles:

```sh
bin/bench compare results/<A>/result.json results/<B>/result.json --force
```

## Repeat Runs

```sh
bin/bench run baseline --source upstream --repeat 3
```

Repeats keep every raw result and print median throughput across completed runs.

## Metrics

- Throughput, including a per-second series
- Latency percentiles for enqueue-to-start and enqueue-to-finish
- MySQL container CPU samples from `docker stats`
- Queue depth samples for ready, scheduled, claimed, blocked, failed, and completed jobs
- Top statement digests from MySQL `performance_schema`

## Adding a Scenario

1. Add defaults, validation, and expected-total logic in `lib/bench/scenarios.rb`.
2. Add the enqueue branch in `harness/script/drive.rb`.
3. Add any job class needed under `harness/app/jobs/`.

Scenario params become CLI-settable through repeated `--set key=val` flags.

## Development

```sh
mise run test
mise run smoke
```

`mise run test` runs orchestrator unit tests. `mise run smoke` runs a 100-job upstream benchmark
against the smoke profile.
