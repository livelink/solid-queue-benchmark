# lib/bench/progress_reporter.rb
module Bench
  class ProgressReporter
    def initialize(expected_total:, io: $stdout, window: 12, plain_interval: 10)
      @expected_total = expected_total
      @io = io
      @window = window
      @plain_interval = plain_interval
      @tty = io.respond_to?(:tty?) && io.tty?
      @last_plain_t = nil
    end

    def update(samples)
      return if samples.empty?

      latest = samples.last
      eta = self.class.eta_seconds(samples, @expected_total, window: @window)
      line = self.class.format_line(latest["completed"], @expected_total, eta)

      if @tty
        @io.print("\r#{line}\e[K")
      else
        t = latest["t"]
        return if @last_plain_t && (t - @last_plain_t) < @plain_interval
        @last_plain_t = t
        @io.puts(line)
      end
    end

    def finish
      @io.print("\n") if @tty
    end

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

    def self.format_line(completed, expected_total, eta_seconds)
      pct = expected_total.zero? ? 0.0 : (100.0 * completed / expected_total).round(1)
      eta_str = eta_seconds ? "ETA #{format_duration(eta_seconds)}" : "ETA calculating..."
      format("%d/%d completed (%.1f%%) | %s", completed, expected_total, pct, eta_str)
    end
  end
end
