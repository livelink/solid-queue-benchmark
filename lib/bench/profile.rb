# lib/bench/profile.rb
require "yaml"

module Bench
  class Profile
    ATTRS = %i[name db_cpus db_memory workers threads polling_interval dispatchers].freeze
    attr_reader(*ATTRS)

    # name_or_path: a bare profile name resolved under profiles/, or a path to a yml.
    # overrides: {workers:, threads:, db_cpus:, db_memory:} from CLI flags.
    def self.load(name_or_path, overrides = {})
      path = if name_or_path.include?("/") || name_or_path.end_with?(".yml")
        File.expand_path(name_or_path)
      else
        File.expand_path("../../profiles/#{name_or_path}.yml", __dir__)
      end
      raw = YAML.safe_load_file(path) || {}
      new(
        name: File.basename(path, ".yml"),
        db_cpus: (overrides[:db_cpus] || raw.dig("db", "cpus") || 1.0).to_f,
        db_memory: (overrides[:db_memory] || raw.dig("db", "memory") || "1g").to_s,
        workers: (overrides[:workers] || raw.dig("workers", "count") || 10).to_i,
        threads: (overrides[:threads] || raw.dig("workers", "threads") || 2).to_i,
        polling_interval: (raw.dig("workers", "polling_interval") || 0.1).to_f,
        dispatchers: (raw.dig("dispatcher", "count") || 1).to_i
      )
    end

    def initialize(name:, db_cpus:, db_memory:, workers:, threads:, polling_interval:, dispatchers:)
      @name = name
      @db_cpus = db_cpus
      @db_memory = db_memory
      @workers = workers
      @threads = threads
      @polling_interval = polling_interval
      @dispatchers = dispatchers
    end

    def env
      {
        "BENCH_DB_CPUS" => db_cpus.to_s,
        "BENCH_DB_MEMORY" => db_memory,
        "BENCH_WORKER_PROCESSES" => workers.to_s,
        "BENCH_WORKER_THREADS" => threads.to_s,
        "BENCH_POLLING_INTERVAL" => polling_interval.to_s
      }
    end

    # Total solid_queue processes expected to register.
    def expected_process_count(process_launcher: "supervisor")
      case process_launcher
      when "supervisor"
        1 + workers + dispatchers
      when "direct"
        workers + dispatchers
      else
        raise ArgumentError, "unknown process launcher #{process_launcher.inspect}"
      end
    end

    def to_h
      ATTRS.to_h { |a| [a, public_send(a)] }
    end
  end
end
