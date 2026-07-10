class SprawlLimitedJob < SprawlJob
  limits_concurrency to: 25, key: ->(*) { "sprawl_limited" }, duration: 10.minutes
end
