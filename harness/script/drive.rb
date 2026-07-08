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
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    enqueued = 0
    credit = 0.0
    tick_index = 0
    begin
      while enqueued < jobs
        credit += rate * tick
        batch_size = [credit.floor, jobs - enqueued].min
        if batch_size.positive?
          ActiveJob.perform_all_later(Array.new(batch_size) { BaselineJob.new(work_ms) })
          enqueued += batch_size
          credit -= batch_size
        end
        tick_index += 1
        next_at = started + tick_index * tick
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep(next_at - now) if next_at > now
      end
    rescue => e
      warn "drive.rb: crashed after enqueuing #{enqueued}/#{jobs}: #{e.class}: #{e.message}"
      raise
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
