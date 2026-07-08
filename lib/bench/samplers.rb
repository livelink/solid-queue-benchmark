# lib/bench/samplers.rb
require "json"

module Bench
  class CpuSampler
    attr_reader :samples

    def initialize(container: "sq-bench-mysql")
      @container = container
      @samples = []
    end

    def start
      @io = IO.popen(["docker", "stats", "--format", "{{json .}}", @container], "r")
      @thread = Thread.new do
        @io.each_line do |line|
          # docker interleaves ANSI clear codes even in some non-TTY contexts; strip to the JSON
          json_start = line.index("{")
          next unless json_start
          data = JSON.parse(line[json_start..]) rescue next
          cpu = data["CPUPerc"].to_s.delete("%").to_f
          @samples << { "t" => Time.now.to_f.round(1), "cpu_pct" => cpu }
        end
      end
      self
    end

    def stop
      Process.kill("TERM", @io.pid) rescue nil
      @io.close rescue nil
      @thread&.join(5)
      @samples
    end
  end

  class DepthSampler
    DEPTH_SQL = <<~SQL.tr("\n", " ").freeze
      SELECT
        (SELECT COUNT(*) FROM solid_queue_ready_executions),
        (SELECT COUNT(*) FROM solid_queue_scheduled_executions),
        (SELECT COUNT(*) FROM solid_queue_claimed_executions),
        (SELECT COUNT(*) FROM solid_queue_blocked_executions),
        (SELECT COUNT(*) FROM bench_events)
    SQL

    attr_reader :samples

    def initialize(client:, interval: 1.0)
      @client = client
      @interval = interval
      @samples = []
      @stop = false
    end

    def start
      @thread = Thread.new do
        until @stop
          begin
            row = @client.query(DEPTH_SQL).first
            if row
              @samples << {
                "t" => Time.now.to_f.round(1),
                "ready" => row[0].to_i, "scheduled" => row[1].to_i,
                "claimed" => row[2].to_i, "blocked" => row[3].to_i,
                "completed" => row[4].to_i
              }
            end
          rescue StandardError
            # transient: skip this sample
          end
          sleep @interval
        end
      end
      self
    end

    def latest = @samples.last

    def stop
      @stop = true
      @thread&.join(@interval + 5)
      @samples
    end
  end
end
