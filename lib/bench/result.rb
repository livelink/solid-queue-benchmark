# lib/bench/result.rb
require "json"
require "fileutils"

module Bench
  # Nested hashes are symbol-keyed when freshly built via .new,
  # string-keyed after .load — don't mix access styles.
  class Result
    FIELDS = %i[run_id database scenario source profile status error timings metrics].freeze
    attr_accessor(*FIELDS)

    def initialize(**attrs)
      FIELDS.each { |f| public_send("#{f}=", attrs[f]) }
    end

    def self.load(path)
      data = JSON.parse(File.read(path))
      new(**FIELDS.to_h { |f| [f, data[f.to_s]] })
    end

    def to_h = FIELDS.to_h { |f| [f, public_send(f)] }

    def write(results_dir:)
      dir = run_dir(results_dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "result.json")
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(to_h))
      File.rename(tmp, path)
      path
    end

    def logs_dir(results_dir:)
      dir = File.join(run_dir(results_dir), "logs")
      FileUtils.mkdir_p(dir)
      dir
    end

    private

    def run_dir(results_dir)
      unless run_id.is_a?(String) && run_id.match?(/\A[\w.-]+\z/) && !run_id.match?(/\A\.+\z/)
        raise ArgumentError, "unsafe run_id: #{run_id.inspect}"
      end
      File.join(results_dir, run_id)
    end
  end
end
