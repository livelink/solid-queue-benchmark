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
  end
end
