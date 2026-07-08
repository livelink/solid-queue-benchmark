# lib/bench/profile.rb
require "yaml"

module Bench
  class Profile
    ATTRS = %i[name mysql_cpus mysql_memory workers threads polling_interval dispatchers].freeze
    attr_reader(*ATTRS)

    # name_or_path: a bare profile name resolved under profiles/, or a path to a yml.
    # overrides: {workers:, threads:, mysql_cpus:, mysql_memory:} from CLI flags.
    def self.load(name_or_path, overrides = {})
      path = if name_or_path.include?("/") || name_or_path.end_with?(".yml")
        File.expand_path(name_or_path)
      else
        File.expand_path("../../profiles/#{name_or_path}.yml", __dir__)
      end
      # Use load_file (not safe_load_file) for compatibility with older Psych
      # versions (e.g. the system Ruby that `mise run test`'s subshell may
      # resolve to lacks Psych::safe_load_file). These are trusted, repo-local
      # YAML files, not user-supplied input, so unrestricted loading is fine.
      raw = YAML.load_file(path)
      new(
        name: File.basename(path, ".yml"),
        mysql_cpus: (overrides[:mysql_cpus] || raw.dig("mysql", "cpus") || 1.0).to_f,
        mysql_memory: (overrides[:mysql_memory] || raw.dig("mysql", "memory") || "1g").to_s,
        workers: (overrides[:workers] || raw.dig("workers", "count") || 10).to_i,
        threads: (overrides[:threads] || raw.dig("workers", "threads") || 2).to_i,
        polling_interval: (raw.dig("workers", "polling_interval") || 0.1).to_f,
        dispatchers: (raw.dig("dispatcher", "count") || 1).to_i
      )
    end

    def initialize(name:, mysql_cpus:, mysql_memory:, workers:, threads:, polling_interval:, dispatchers:)
      @name = name
      @mysql_cpus = mysql_cpus
      @mysql_memory = mysql_memory
      @workers = workers
      @threads = threads
      @polling_interval = polling_interval
      @dispatchers = dispatchers
    end

    def env
      {
        "BENCH_MYSQL_CPUS" => mysql_cpus.to_s,
        "BENCH_MYSQL_MEMORY" => mysql_memory,
        "BENCH_WORKER_PROCESSES" => workers.to_s,
        "BENCH_WORKER_THREADS" => threads.to_s,
        "BENCH_POLLING_INTERVAL" => polling_interval.to_s
      }
    end

    # Total solid_queue processes expected to register: supervisor + workers + dispatchers.
    def expected_process_count
      1 + workers + dispatchers
    end

    def to_h
      ATTRS.to_h { |a| [a, public_send(a)] }
    end
  end
end
