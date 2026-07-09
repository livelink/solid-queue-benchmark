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
        begin
          @io.each_line do |line|
            cpu = self.class.parse_cpu_pct(line)
            next unless cpu
            @samples << { "t" => Time.now.to_f.round(1), "cpu_pct" => cpu }
          end
        rescue IOError, Errno::EBADF
          # io closed during shutdown — expected
        end
      end
      self
    end

    # docker interleaves ANSI cursor/clear codes even in non-TTY contexts, both
    # around AND after the JSON object on the same line — slice to the matching
    # closing brace, not just to end of line, or JSON.parse rejects the trailing bytes.
    def self.parse_cpu_pct(line)
      json_start = line.index("{")
      json_end = line.rindex("}")
      return nil unless json_start && json_end
      begin
        data = JSON.parse(line[json_start..json_end])
      rescue JSON::ParserError
        return nil
      end
      data["CPUPerc"].to_s.delete("%").to_f
    end

    def stop
      Process.kill("TERM", @io.pid) rescue nil
      unless @thread&.join(5)
        # child ignored TERM; escalate so close/reap below can't block
        Process.kill("KILL", @io.pid) rescue nil
        @thread&.join(2)
      end
      @io.close rescue nil # reaps the popen child and sets $?
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
        (SELECT COUNT(*) FROM solid_queue_failed_executions),
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
                "failed" => row[4].to_i, "completed" => row[5].to_i
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
