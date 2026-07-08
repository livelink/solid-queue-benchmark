# lib/bench/result.rb
require "json"
require "fileutils"

module Bench
  class Result
    FIELDS = %i[run_id scenario source profile status error timings metrics].freeze
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
      dir = File.join(results_dir, run_id)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "result.json")
      File.write(path, JSON.pretty_generate(to_h))
      path
    end

    def logs_dir(results_dir:)
      dir = File.join(results_dir, run_id, "logs")
      FileUtils.mkdir_p(dir)
      dir
    end
  end
end
