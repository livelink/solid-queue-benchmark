# lib/bench/svg_chart.rb
require "cgi"

module Bench
  module SvgChart
    W = 720
    H = 240
    PAD_LEFT = 54
    PAD_RIGHT = 18
    PAD_TOP = 30
    PAD_BOTTOM = 42

    module_function

    # series: [{ label:, color:, points: [[x, y], ...] }]
    def line_chart(title:, series:, y_label: "")
      all_points = series.flat_map { |s| s[:points] }
      return %(<p>(no data: #{h(title)})</p>) if all_points.empty?

      x_min, x_max = all_points.map(&:first).minmax
      y_min = 0.0
      y_max = [all_points.map(&:last).max.to_f, 1.0].max
      x_span = [x_max - x_min, 0.001].max

      sx = ->(x) { PAD_LEFT + (x - x_min) / x_span * (W - PAD_LEFT - PAD_RIGHT) }
      sy = ->(y) { H - PAD_BOTTOM - (y - y_min) / (y_max - y_min) * (H - PAD_TOP - PAD_BOTTOM) }

      grid = y_ticks(y_max).map do |tick|
        y = sy.call(tick).round(1)
        %(<line x1="#{PAD_LEFT}" y1="#{y}" x2="#{W - PAD_RIGHT}" y2="#{y}" stroke="#e5e7eb"/>) \
          + %(<text x="#{PAD_LEFT - 8}" y="#{y + 3}" text-anchor="end" font-size="10" fill="#64748b">#{tick.round(1)}</text>)
      end

      polylines = series.map do |s|
        points = s[:points].map { |x, y| "#{sx.call(x).round(1)},#{sy.call(y).round(1)}" }.join(" ")
        %(<polyline fill="none" stroke="#{s[:color]}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="#{points}"/>)
      end

      legend = series.each_with_index.map do |s, i|
        x = PAD_LEFT + i * 210
        %(<line x1="#{x}" y1="15" x2="#{x + 18}" y2="15" stroke="#{s[:color]}" stroke-width="2"/>) \
          + %(<text x="#{x + 24}" y="19" fill="#334155" font-size="12">#{h(s[:label])}</text>)
      end

      <<~SVG
        <svg viewBox="0 0 #{W} #{H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="#{h(title)}">
          <rect x="0" y="0" width="#{W}" height="#{H}" fill="#ffffff"/>
          #{grid.join("\n  ")}
          <line x1="#{PAD_LEFT}" y1="#{H - PAD_BOTTOM}" x2="#{W - PAD_RIGHT}" y2="#{H - PAD_BOTTOM}" stroke="#94a3b8"/>
          <line x1="#{PAD_LEFT}" y1="#{PAD_TOP}" x2="#{PAD_LEFT}" y2="#{H - PAD_BOTTOM}" stroke="#94a3b8"/>
          <text x="#{W / 2}" y="#{H - 10}" text-anchor="middle" font-size="11" fill="#475569">seconds</text>
          <text x="14" y="#{H / 2}" font-size="11" fill="#475569" transform="rotate(-90 14 #{H / 2})" text-anchor="middle">#{h(y_label)}</text>
          #{legend.join("\n  ")}
          #{polylines.join("\n  ")}
        </svg>
      SVG
    end

    def y_ticks(y_max)
      step = y_max / 4.0
      0.upto(4).map { |i| step * i }
    end

    def h(str)
      CGI.escapeHTML(str.to_s)
    end
  end
end
