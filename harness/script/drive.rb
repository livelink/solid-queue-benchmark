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
