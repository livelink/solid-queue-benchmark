# lib/bench/stats.rb
module Bench
  module Stats
    module_function

    def percentile(values, p)
      return nil if values.empty?
      percentile_of_sorted(values.sort, p)
    end

    def summary(values)
      return { count: 0 } if values.empty?
      sorted = values.sort
      {
        count: sorted.length,
        mean: (sorted.sum / sorted.length.to_f).round(2),
        p50: percentile_of_sorted(sorted, 50).round(2),
        p95: percentile_of_sorted(sorted, 95).round(2),
        p99: percentile_of_sorted(sorted, 99).round(2),
        max: sorted.last.to_f.round(2)
      }
    end

    # Assumes `sorted` is non-empty and already sorted ascending.
    def percentile_of_sorted(sorted, p)
      rank = (p / 100.0) * (sorted.length - 1)
      lo = sorted[rank.floor]
      hi = sorted[rank.ceil]
      lo + (hi - lo) * (rank - rank.floor)
    end

    # timestamps: array of unix-time floats -> [[second, count], ...] with gaps zero-filled
    def per_second(timestamps)
      return [] if timestamps.empty?
      counts = timestamps.group_by { |t| t.to_i }.transform_values(&:length)
      (counts.keys.min..counts.keys.max).map { |sec| [sec, counts.fetch(sec, 0)] }
    end
  end
end
