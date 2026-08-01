# lib/bench/cli.rb
require "json"
require "optparse"
require "bench/source_spec"
require "bench/profile"
require "bench/scenarios"
require "bench/engines"

module Bench
  module CLI
    ROOT = File.expand_path("../..", __dir__)

    module_function

    def start(argv)
      case argv.first
      when "run" then run(argv.drop(1))
      when "list" then list
      when "setup" then setup
      when "compare" then compare(argv.drop(1))
      else
        puts usage
        exit(argv.empty? ? 0 : 1)
      end
    rescue ArgumentError => e
      warn "error: #{e.message}"
      exit 1
    end

    def usage
      <<~USAGE
        Usage: bin/bench <command>
          run <scenario> --source <src> [options]   Run a benchmark
          compare <result.json> <result.json>       Compare two runs
          list                                      List past runs
          setup                                     Bundle default source + pull database images

        Scenarios: #{Scenarios.names.join(", ")}
        Sources:   upstream | upstream@1.2.4 | path:/dir/of/solid_queue
        Databases: #{Engines.names.join(" | ")} (default: mysql)
      USAGE
    end

    def parse_run_options(argv)
      opts = {
        profile: "default",
        params: {},
        overrides: {},
        timeout: 900,
        repeat: 1,
        allow_dirty: false,
        database: "mysql"
      }
      parser = OptionParser.new do |o|
        o.on("--source SRC") { |v| opts[:source] = v }
        o.on("--profile NAME") { |v| opts[:profile] = v }
        o.on("--database ENGINE") { |v| opts[:database] = v }
        o.on("--set KEY=VAL", "Scenario param override (repeatable)") do |v|
          key, value = v.split("=", 2)
          raise ArgumentError, "--set must be KEY=VAL" if key.nil? || key.empty? || value.nil?
          opts[:params][key] = value
        end
        o.on("--workers N", Integer) { |v| opts[:overrides][:workers] = v }
        o.on("--threads N", Integer) { |v| opts[:overrides][:threads] = v }
        o.on("--db-cpus N", Float) { |v| opts[:overrides][:db_cpus] = v }
        o.on("--db-memory SIZE") { |v| opts[:overrides][:db_memory] = v }
        o.on("--timeout SECONDS", Integer) { |v| opts[:timeout] = v }
        o.on("--repeat N", Integer) { |v| opts[:repeat] = v }
        o.on("--allow-dirty") { opts[:allow_dirty] = true }
      end
      positional = parser.parse(argv)
      opts[:scenario] = positional.first
      raise ArgumentError, "scenario required (#{Scenarios.names.join(", ")})" unless opts[:scenario]
      raise ArgumentError, "--source required" unless opts[:source]
      raise ArgumentError, "--repeat must be >= 1" if opts[:repeat] < 1
      unless Engines.names.include?(opts[:database])
        raise ArgumentError, "--database must be one of #{Engines.names.join(", ")} (got #{opts[:database].inspect})"
      end
      opts
    end

    def run(argv)
      require "bench/runner"
      opts = parse_run_options(argv)
      scenario = Scenarios.build(opts[:scenario], opts[:params])
      source = SourceSpec.parse(opts[:source])
      profile = Profile.load(opts[:profile], opts[:overrides])

      results = opts[:repeat].times.map do |i|
        puts "== run #{i + 1}/#{opts[:repeat]}: #{scenario.name} | #{source} | #{opts[:database]} | profile #{profile.name}" \
             " (#{profile.workers}w x #{profile.threads}t, #{opts[:database]} #{profile.db_cpus}cpu)"
        Runner.new(
          scenario: scenario,
          source: source,
          profile: profile,
          root: ROOT,
          database: opts[:database],
          timeout: opts[:timeout],
          allow_dirty: opts[:allow_dirty]
        ).call
      end

      summarize_repeats(results) if opts[:repeat] > 1
      exit(results.all? { |r| r.status == "completed" } ? 0 : 1)
    end

    def summarize_repeats(results)
      completed = results.select { |r| r.status == "completed" }
      throughputs = completed.map { |r| r.metrics[:throughput_jobs_per_sec] }.compact.sort
      median = throughputs.empty? ? "-" : throughputs[throughputs.length / 2]
      puts "== #{completed.length}/#{results.length} completed; median throughput: #{median} jobs/sec"
    end

    def list
      paths = Dir.glob(File.join(ROOT, "results", "*", "result.json")).sort
      return puts "no results found" if paths.empty?

      paths.each do |path|
        data = JSON.parse(File.read(path))
        metrics = data["metrics"] || {}
        puts format(
          "%-60s %-9s %10s jobs/sec  cpu avg %s%%",
          data["run_id"],
          data["status"],
          metrics["throughput_jobs_per_sec"] || "-",
          metrics.dig("db_cpu", "avg_pct") || "-"
        )
      end
    end

    def setup
      require "fileutils"
      require "bench/shell"
      source = SourceSpec.parse("upstream")
      FileUtils.mkdir_p(File.join(ROOT, "gemfiles"))
      gemfile = File.join(ROOT, "gemfiles", "#{source.key}.gemfile")
      File.write(gemfile, source.wrapper_gemfile_contents)
      Shell.capture(Shell.bundle_cmd("install"), env: { "BUNDLE_GEMFILE" => gemfile })
      Shell.capture(%w[docker compose pull mysql postgres])
      puts "setup: ok"
    end

    def compare(argv)
      require "bench/compare"
      Compare.run(argv, root: ROOT)
    end
  end
end
