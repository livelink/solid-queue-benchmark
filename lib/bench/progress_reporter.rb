# lib/bench/progress_reporter.rb
module Bench
  class ProgressReporter
    def self.format_duration(seconds)
      total = seconds.round
      hours, remainder = total.divmod(3600)
      minutes, secs = remainder.divmod(60)
      if hours.positive?
        format("%dh %dm %ds", hours, minutes, secs)
      elsif minutes.positive?
        format("%dm %ds", minutes, secs)
      else
        format("%ds", secs)
      end
    end

    def self.eta_seconds(samples, expected_total, window: 12)
      return nil if samples.length < 2

      latest = samples.last
      reference = samples.reverse_each.find { |s| latest["t"] - s["t"] >= window } || samples.first

      dt = latest["t"] - reference["t"]
      dc = latest["completed"] - reference["completed"]
      return nil if dt <= 0 || dc <= 0

      remaining = expected_total - latest["completed"]
      return 0.0 if remaining <= 0

      remaining / (dc / dt)
    end
  end
end
