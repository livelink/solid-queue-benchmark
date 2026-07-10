# Fan-out: each job with depth > 0 enqueues `fanout` children one at a time
# (per-insert enqueue path, as real sprawling jobs do), cycling priorities so
# the wildcard-queue priority ordering is exercised under burst.
class SprawlJob < ApplicationJob
  PRIORITIES = [0, 10, 20].freeze

  def perform(depth:, fanout:, work_ms:)
    if depth.positive?
      fanout.times do |i|
        self.class.set(priority: PRIORITIES[i % PRIORITIES.size])
                  .perform_later(depth: depth - 1, fanout: fanout, work_ms: work_ms)
      end
    end
    sleep(work_ms / 1000.0) if work_ms.positive?
  end
end
