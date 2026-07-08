require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module BenchHarness
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = true
    config.secret_key_base = "bench-harness-not-secret"
    config.active_job.queue_adapter = :solid_queue
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
