require_relative "test_helper"
require "open3"

class TestRperfDiffCli < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  def setup
    omit "Go not available" unless system("go", "version", out: File::NULL, err: File::NULL)
  end

  private

  def run_rperf(*args, env: {})
    cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, *args]
    stdout, stderr, status = Open3.capture3(env, *cmd)
    [stdout, stderr, status]
  end

  def create_profile(dir, name, workload)
    path = File.join(dir, name)
    _, stderr, status = run_rperf("record", "-f", "100", "-o", path,
                                  RbConfig.ruby, "-e", workload)
    assert_equal 0, status.exitstatus, "Failed to create profile #{name}: #{stderr}"
    assert File.exist?(path), "Profile #{name} should exist"
    path
  end

  public

  def test_diff_with_json_gz_files
    Dir.mktmpdir do |dir|
      base = create_profile(dir, "base.json.gz", "3_000_000.times { 1 + 1 }")
      target = create_profile(dir, "target.json.gz", "5_000_000.times { 1 + 1 }")

      stdout, stderr, status = run_rperf("diff", "--top", base, target)
      assert_equal 0, status.exitstatus, "rperf diff --top should succeed: #{stderr}"
      # --top produces pprof top output
      assert_match(/flat|cum/i, stdout, "diff --top should print flat/cumulative info")
    end
  end

  def test_diff_with_pb_gz_files
    Dir.mktmpdir do |dir|
      base = create_profile(dir, "base.pb.gz", "3_000_000.times { 1 + 1 }")
      target = create_profile(dir, "target.pb.gz", "5_000_000.times { 1 + 1 }")

      stdout, stderr, status = run_rperf("diff", "--top", base, target)
      assert_equal 0, status.exitstatus, "rperf diff --top with .pb.gz should succeed: #{stderr}"
      assert_match(/flat|cum/i, stdout, "diff --top should print flat/cumulative info")
    end
  end

  def test_diff_missing_file
    _, stderr, status = run_rperf("diff", "--top", "nonexistent_base.pb.gz", "nonexistent_target.pb.gz")
    assert_not_equal 0, status.exitstatus, "rperf diff should fail for missing files"
    assert_match(/not found/i, stderr)
  end

  def test_diff_help
    stdout, _, status = run_rperf("diff", "-h")
    assert_equal 0, status.exitstatus
    assert_include stdout, "Usage: rperf diff"
    assert_include stdout, "--top"
    assert_include stdout, "--text"
  end
end
