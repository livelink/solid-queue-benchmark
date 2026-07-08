# lib/bench/compare.rb
require "cgi"
require "fileutils"
require "bench/result"
require "bench/svg_chart"

module Bench
  module Compare
    ProfileMismatch = Class.new(StandardError)

    METRIC_ROWS = [
      ["Throughput (jobs/sec)", ->(m) { m["throughput_jobs_per_sec"] }, :higher_better],
      ["Enqueue to start p50 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p50") }, :lower_better],
      ["Enqueue to start p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p95") }, :lower_better],
      ["Enqueue to start p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_start", "p99") }, :lower_better],
      ["Enqueue to finish p95 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p95") }, :lower_better],
      ["Enqueue to finish p99 (ms)", ->(m) { m.dig("latency_ms", "enqueue_to_finish", "p99") }, :lower_better],
      ["MySQL CPU avg (%)", ->(m) { m.dig("mysql_cpu", "avg_pct") }, :lower_better],
      ["MySQL CPU max (%)", ->(m) { m.dig("mysql_cpu", "max_pct") }, :lower_better]
    ].freeze

    module_function

    def run(argv, root:)
      force = argv.delete("--force") ? true : false
      a_path, b_path = argv
      abort "usage: bin/bench compare <a/result.json> <b/result.json> [--force]" unless a_path && b_path

      a = Result.load(a_path)
      b = Result.load(b_path)
      out_dir = File.join(root, "reports", "#{a.run_id}__vs__#{b.run_id}")
      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "report.md"), render_markdown(a, b, force: force))
      File.write(File.join(out_dir, "report.html"), render_html(a, b, force: force))
      puts "reports written to #{out_dir}"
    end

    def render_markdown(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      lines = []
      lines << "# solid_queue benchmark comparison"
      lines << ""
      lines << "> #{warning.gsub("\n", " ")}" if warning
      lines << "| | A | B |"
      lines << "|---|---|---|"
      lines << "| Run | #{a.run_id} | #{b.run_id} |"
      lines << "| Source | #{source_label(a)} | #{source_label(b)} |"
      lines << "| Scenario | #{scenario_label(a)} | #{scenario_label(b)} |"
      lines << "| Profile | #{a.profile} | #{b.profile} |"
      lines << ""
      lines << "## Metrics (B relative to A)"
      lines << ""
      lines << "| Metric | A | B | Delta |"
      lines << "|---|---:|---:|---:|"
      METRIC_ROWS.each do |label, extractor, direction|
        av = extractor.call(a.metrics)
        bv = extractor.call(b.metrics)
        lines << "| #{label} | #{fmt(av)} | #{fmt(bv)} | #{delta(av, bv, direction)} |"
      end
      lines << ""
      lines << "## Top statements by total DB time"
      append_statement_table(lines, "A", a)
      append_statement_table(lines, "B", b)
      lines.join("\n") + "\n"
    end

    def render_html(a, b, force:)
      warning = check_profiles!(a, b, force: force)
      cpu_chart = SvgChart.line_chart(
        title: "MySQL CPU %",
        y_label: "MySQL CPU %",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#2563eb", points: normalize_series(a.metrics.dig("mysql_cpu", "series"), "cpu_pct") },
          { label: "B: #{b.source["spec"]}", color: "#dc2626", points: normalize_series(b.metrics.dig("mysql_cpu", "series"), "cpu_pct") }
        ]
      )
      depth_chart = SvgChart.line_chart(
        title: "Ready queue depth",
        y_label: "ready executions",
        series: [
          { label: "A: #{a.source["spec"]}", color: "#2563eb", points: normalize_series(a.metrics["queue_depth_series"], "ready") },
          { label: "B: #{b.source["spec"]}", color: "#dc2626", points: normalize_series(b.metrics["queue_depth_series"], "ready") }
        ]
      )
      md = render_markdown(a, b, force: true)

      <<~HTML
        <!doctype html>
        <meta charset="utf-8">
        <title>solid_queue benchmark: #{h(a.run_id)} vs #{h(b.run_id)}</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 920px; margin: 2rem auto; padding: 0 1rem; color: #0f172a; }
          h1, h2 { line-height: 1.15; }
          pre { background: #f8fafc; border: 1px solid #e2e8f0; padding: 1rem; overflow-x: auto; white-space: pre-wrap; }
          svg { width: 100%; height: auto; border: 1px solid #e2e8f0; margin: 0.75rem 0 1.5rem; }
          .warning { border-left: 4px solid #f59e0b; padding: 0.75rem 1rem; background: #fffbeb; }
        </style>
        <h1>solid_queue benchmark comparison</h1>
        #{warning ? %(<p class="warning"><strong>#{h(warning).gsub("\n", "<br>")}</strong></p>) : ""}
        <h2>MySQL CPU over time</h2>
        #{cpu_chart}
        <h2>Ready queue depth over time</h2>
        #{depth_chart}
        <h2>Full comparison markdown</h2>
        <pre>#{h(md)}</pre>
      HTML
    end

    def check_profiles!(a, b, force:)
      pa = comparable_profile(a.profile)
      pb = comparable_profile(b.profile)
      return nil if pa == pb

      message = "PROFILES DIFFER: this comparison mixes topology and gem changes.\nA: #{pa}\nB: #{pb}"
      raise ProfileMismatch, message unless force
      message
    end

    def comparable_profile(profile)
      profile.reject { |k, _| k.to_s == "name" }
    end

    def delta(a_val, b_val, direction)
      return "" if a_val.nil? || b_val.nil? || a_val.to_f.zero?

      pct = ((b_val.to_f - a_val.to_f) / a_val.to_f * 100).round(1)
      sign = pct.positive? ? "+" : ""
      better = direction == :higher_better ? pct.positive? : pct.negative?
      "#{sign}#{pct}% #{better ? "better" : "worse"}"
    end

    def fmt(value)
      value.nil? ? "-" : value
    end

    def source_label(result)
      sha = result.source["sha"]
      short_sha = sha ? ", #{sha[0, 12]}" : ""
      "#{result.source["spec"]} (#{result.source["resolved_version"]}#{short_sha})"
    end

    def scenario_label(result)
      "#{result.scenario["name"]} #{result.scenario["params"]}"
    end

    def append_statement_table(lines, tag, result)
      lines << ""
      lines << "### #{tag}: #{result.run_id}"
      lines << ""
      lines << "| Statement | Count | Total ms | Rows examined |"
      lines << "|---|---:|---:|---:|"
      Array(result.metrics["top_statements"]).first(10).each do |statement|
        text = statement["digest_text"].to_s.gsub("|", "\\|").gsub("`", "")[0, 120]
        lines << "| `#{text}` | #{statement["count"]} | #{statement["total_ms"]} | #{statement["rows_examined"]} |"
      end
    end

    def normalize_series(series, key)
      series = Array(series)
      return [] if series.empty?

      t0 = series.first["t"]
      series.map { |sample| [(sample["t"] - t0).round(1), sample[key].to_f] }
    end

    def h(str)
      CGI.escapeHTML(str.to_s)
    end
  end
end
