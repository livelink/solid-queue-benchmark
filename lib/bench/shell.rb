# lib/bench/shell.rb
require "open3"

module Bench
  module Shell
    Error = Class.new(StandardError)

    module_function

    # Run a command, return stdout. Raises Bench::Shell::Error on non-zero exit.
    def capture(cmd, env: {}, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      stdout, stderr, status = Open3.capture3(env, *cmd, **opts)
      unless status.success?
        raise Error, "command failed (#{status.exitstatus}): #{cmd.join(" ")}\n#{stderr}"
      end
      stdout
    end

    # Run a command streaming output to a log file; returns the pid.
    def spawn_logged(cmd, env: {}, log_path:, chdir: nil)
      log = File.open(log_path, "a")
      opts = { out: log, err: log }
      opts[:chdir] = chdir if chdir
      pid = Process.spawn(env, *cmd, **opts)
      log.close
      pid
    end
  end
end
