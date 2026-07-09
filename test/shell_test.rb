# test/shell_test.rb
require "test_helper"
require "bench/shell"
require "rbconfig"
require "tmpdir"

class ShellTest < Minitest::Test
  def test_capture_returns_stdout
    assert_equal "hi\n", Bench::Shell.capture(%w[echo hi])
  end

  def test_capture_raises_on_failure_with_stderr
    err = assert_raises(Bench::Shell::Error) do
      Bench::Shell.capture(["ruby", "-e", 'warn("boom"); exit(3)'])
    end
    assert_includes err.message, "boom"
    assert_includes err.message, "(3)"
  end

  def test_capture_raises_on_failure_with_stdout
    err = assert_raises(Bench::Shell::Error) do
      Bench::Shell.capture(["ruby", "-e", 'puts("boom"); exit(3)'])
    end
    assert_includes err.message, "boom"
    assert_includes err.message, "(3)"
  end

  def test_capture_honors_chdir
    Dir.mktmpdir do |dir|
      real = File.realpath(dir)
      assert_equal "#{real}\n", Bench::Shell.capture(%w[pwd], chdir: real)
    end
  end

  def test_ruby_cmd_uses_current_ruby
    assert_equal [RbConfig.ruby, "-e", "puts 1"], Bench::Shell.ruby_cmd("-e", "puts 1")
  end

  def test_bundle_cmd_uses_current_ruby
    assert_equal [RbConfig.ruby, "-S", "bundle", "check"], Bench::Shell.bundle_cmd("check")
  end
end
