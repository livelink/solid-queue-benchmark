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
