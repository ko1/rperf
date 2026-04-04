require "test-unit"
require "rperf"
require "tempfile"
require "zlib"

module RperfTestHelper
  def teardown
    Rperf.stop rescue nil
    # Clean up env vars and state that may have been set by Rperf.start(inherit: ...)
    ENV.delete("RPERF_SESSION_DIR")
    ENV.delete("RPERF_ROOT_PROCESS")
    ENV.delete("RPERF_ENABLED")
    ENV.delete("RPERF_STAT_COMMAND")
    ENV.delete("RPERF_STAT_REPORT")
    Rperf.instance_variable_set(:@_session_dir_created, false)
    # Clean up session dirs that may have been created
    require "tmpdir"
    user_dir = File.join(Dir.tmpdir, "rperf-#{Process.uid}")
    if File.directory?(user_dir)
      require "fileutils"
      Dir.glob(File.join(user_dir, "rperf-*")).each do |dir|
        FileUtils.rm_rf(dir)
      end
    end
  end

  private

  def cpu_work_with_gvl_yield(n = 50_000_000)
    chunk = 500_000
    (n / chunk).times do
      chunk.times { 1 + 1 }
      sleep(0)
    end
  end

  def busy_wait(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
  end

  def deep_recurse(depth, &block)
    if depth <= 0
      block.call
    else
      deep_recurse(depth - 1, &block)
    end
  end

  def assert_valid_samples(samples)
    samples.each_with_index do |(frames, weight), i|
      assert_operator weight, :>, 0, "Sample #{i}: weight should be positive"
      assert_operator frames.size, :>, 0, "Sample #{i}: should have at least 1 frame"
      frames.each_with_index do |frame, j|
        assert_kind_of String, frame[0], "Sample #{i} frame #{j}: path should be String"
        assert_kind_of String, frame[1], "Sample #{i} frame #{j}: label should be String"
      end
    end
  end
end
