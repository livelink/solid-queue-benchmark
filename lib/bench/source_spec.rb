# lib/bench/source_spec.rb
require "open3"

module Bench
  SourceSpec = Struct.new(:kind, :version, :path, keyword_init: true) do
    def self.parse(str)
      case str
      when "upstream"
        new(kind: :upstream)
      when /\Aupstream@(.+)\z/
        new(kind: :upstream, version: Regexp.last_match(1))
      when /\Apath:(.+)\z/
        new(kind: :path, path: File.expand_path(Regexp.last_match(1)))
      else
        raise ArgumentError, "invalid source spec: #{str.inspect} (expected upstream, upstream@VERSION, or path:DIR)"
      end
    end

    def key
      kind == :path ? "path-#{File.basename(path)}" : "upstream-#{version || "latest"}"
    end

    def to_s
      kind == :path ? "path:#{path}" : (version ? "upstream@#{version}" : "upstream")
    end

    def wrapper_gemfile_contents
      <<~RUBY
        ENV["SOLID_QUEUE_SOURCE"] = #{to_s.inspect}
        eval_gemfile File.expand_path("../Gemfile", __dir__)
      RUBY
    end

    def git_sha
      return nil unless kind == :path
      out, status = Open3.capture2("git", "-C", path, "rev-parse", "HEAD")
      status.success? ? out.strip : nil
    end

    def git_dirty?
      return false unless kind == :path
      out, status = Open3.capture2("git", "-C", path, "status", "--porcelain")
      status.success? && !out.strip.empty?
    end
  end
end
