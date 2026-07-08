class BaselineJob < ApplicationJob
  def perform(work_ms)
    sleep(work_ms / 1000.0) if work_ms.positive?
  end
end
