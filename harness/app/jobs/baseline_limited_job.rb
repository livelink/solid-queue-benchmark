class BaselineLimitedJob < BaselineJob
  limits_concurrency to: 1, key: ->(*) { "baseline_limited" }, duration: 10.minutes
end
