# test/source_spec_test.rb
require "test_helper"
require "bench/source_spec"
require "tmpdir"
require "digest"

class SourceSpecTest < Minitest::Test
  def test_parses_upstream_latest
    spec = Bench::SourceSpec.parse("upstream")
    assert_equal :upstream, spec.kind
    assert_nil spec.version
    assert_equal "upstream-latest", spec.key
    assert_equal "upstream", spec.to_s
  end

  def test_parses_upstream_pinned
    spec = Bench::SourceSpec.parse("upstream@1.2.4")
    assert_equal :upstream, spec.kind
    assert_equal "1.2.4", spec.version
    assert_equal "upstream-1.2.4", spec.key
    assert_equal "upstream@1.2.4", spec.to_s
  end

  def test_parses_path
    spec = Bench::SourceSpec.parse("path:~/Projects/solid_queue")
    expanded = File.expand_path("~/Projects/solid_queue")
    assert_equal :path, spec.kind
    assert_equal expanded, spec.path
    assert_equal "path-solid_queue-#{Digest::SHA256.hexdigest(expanded)[0, 8]}", spec.key
    assert_equal "path:#{expanded}", spec.to_s
  end

  def test_path_keys_differ_for_same_basename_different_dirs
    a = Bench::SourceSpec.parse("path:/tmp/a/solid_queue")
    b = Bench::SourceSpec.parse("path:/tmp/b/solid_queue")
    refute_equal a.key, b.key
  end

  def test_rejects_garbage
    assert_raises(ArgumentError) { Bench::SourceSpec.parse("gem:whatever") }
  end

  def test_wrapper_gemfile_pins_env_and_evals_root_gemfile
    spec = Bench::SourceSpec.parse("upstream@1.2.4")
    contents = spec.wrapper_gemfile_contents
    assert_includes contents, %(ENV["SOLID_QUEUE_SOURCE"] = "upstream@1.2.4")
    assert_includes contents, %(eval_gemfile File.expand_path("../Gemfile", __dir__))
  end

  def test_git_info_for_clean_and_dirty_repo
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q")
      File.write(File.join(dir, "a.txt"), "hello")
      system("git", "-C", dir, "add", ".")
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

      spec = Bench::SourceSpec.parse("path:#{dir}")
      assert_match(/\A[0-9a-f]{40}\z/, spec.git_sha)
      refute spec.git_dirty?

      File.write(File.join(dir, "b.txt"), "dirty")
      assert spec.git_dirty?
    end
  end

  def test_git_info_nil_for_non_git_dir_and_no_stderr_leak
    Dir.mktmpdir do |dir|
      spec = Bench::SourceSpec.parse("path:#{dir}")
      out, err = capture_subprocess_io do
        assert_nil spec.git_sha
        refute spec.git_dirty?
      end
      assert_empty out
      assert_empty err
    end
  end

  def test_git_info_nil_for_upstream
    spec = Bench::SourceSpec.parse("upstream")
    assert_nil spec.git_sha
    refute spec.git_dirty?
  end
end
