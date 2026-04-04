require_relative "test_helper"

class TestRperfProfiler < Test::Unit::TestCase
  include RperfTestHelper

  def test_start_stop
    Rperf.start(frequency: 100)
    1_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_kind_of Hash, data
    assert_include data, :aggregated_samples
    assert_include data, :frequency
    assert_equal 100, data[:frequency]
    assert_include data, :detected_thread_count
    assert_operator data[:detected_thread_count], :>=, 1
  end

  def test_cpu_bound_weight
    Rperf.start(frequency: 1000)
    10_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_not_nil data
    samples = data[:aggregated_samples]
    assert_operator samples.size, :>, 0, "Expected at least 1 sample"

    samples.each do |frames, weight|
      assert_operator weight, :>, 0, "Weight should be positive"
    end
  end

  def test_profile_block
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.data")
      Rperf.start(output: path, frequency: 500) do
        5_000_000.times { 1 + 1 }
      end

      assert File.exist?(path), "Output file should exist"
      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"

      decompressed = Zlib::GzipReader.new(StringIO.new(content)).read
      assert_operator decompressed.bytesize, :>, 0
    end
  end

  def test_multithread
    Rperf.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 5_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0, "Should have samples from threads"
  end

  def test_double_start_raises
    Rperf.start(frequency: 100)
    assert_raise(RuntimeError) { Rperf.start(frequency: 100) }
    Rperf.stop
  end

  def test_stop_without_start_returns_nil
    assert_nil Rperf.stop
  end

  def test_restart_clears_thread_state
    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    sleep 0.2

    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    assert_not_nil data1
    assert_not_nil data2

    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 100_000_000,
      "Max weight in second session (#{max_weight2}ns) should not include the gap between sessions"
  end

  def test_repeated_start_stop
    10.times do |cycle|
      Rperf.start(frequency: 1000)
      1_000_000.times { 1 + 1 }
      data = Rperf.stop

      assert_not_nil data, "Cycle #{cycle}: stop should return data"
      assert_operator data[:aggregated_samples].size, :>, 0, "Cycle #{cycle}: should have samples"
    end
  end

  def test_sample_buffer_realloc
    duration = 1.0
    data = nil
    trials = []

    loop do
      Rperf.start(frequency: 5000)
      busy_wait(duration)
      data = Rperf.stop

      trials << "#{duration}s: samples=#{data[:aggregated_samples].size}, trigger_count=#{data[:trigger_count]}, sampling_count=#{data[:sampling_count]}"
      break if data[:sampling_count] > 1024

      duration *= 2
      assert_operator duration, :<=, 32,
        "Expected >1024 sampling_count to exercise realloc. Trials:\n#{trials.map { |t| "  #{t}" }.join("\n")}"
    end

    assert_valid_samples(data[:aggregated_samples])
  end

  def test_frame_pool_realloc
    initial_pool = 1024 * 1024 / 8  # ~131072
    stack_depth = 300
    duration = 1.0
    data = nil
    trials = []

    loop do
      Rperf.start(frequency: 5000)
      deep_recurse(stack_depth) { busy_wait(duration) }
      data = Rperf.stop

      samples = data[:aggregated_samples]
      estimated_frames = data[:sampling_count] * stack_depth
      trials << "#{duration}s: samples=#{samples.size}, sampling_count=#{data[:sampling_count]}, estimated_frames=#{estimated_frames}"
      break if estimated_frames > initial_pool

      duration *= 2
      assert_operator duration, :<=, 32,
        "Expected >#{initial_pool} estimated frames to exercise frame pool realloc. Trials:\n#{trials.map { |t| "  #{t}" }.join("\n")}"
    end

    samples = data[:aggregated_samples]
    assert_valid_samples(samples.first(10))
    assert_valid_samples(samples.last(10))
  end

  def test_deep_stack
    Rperf.start(frequency: 1000)
    deep_recurse(200) { 5_000_000.times { 1 + 1 } }
    data = Rperf.stop

    assert_not_nil data
    samples = data[:aggregated_samples]
    assert_operator samples.size, :>, 0

    max_depth = samples.map { |frames, _| frames.size }.max
    assert_operator max_depth, :>=, 50,
      "Expected deep stacks (max depth #{max_depth})"

    assert_valid_samples(samples)
  end

  def test_thread_churn
    Rperf.start(frequency: 1000)

    20.times do
      threads = 4.times.map do
        Thread.new { cpu_work_with_gvl_yield(500_000) }
      end
      threads.each(&:join)
    end

    data = Rperf.stop
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  def test_restart_with_surviving_thread
    worker_running = true
    worker = Thread.new do
      while worker_running
        500_000.times { 1 + 1 }
        sleep(0)
      end
    end

    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data1 = Rperf.stop

    sleep 0.2

    Rperf.start(frequency: 1000, aggregate: false)
    5_000_000.times { 1 + 1 }
    data2 = Rperf.stop

    worker_running = false
    worker.join

    assert_not_nil data1
    assert_not_nil data2
    assert_operator data2[:raw_samples].size, :>, 0

    max_weight2 = data2[:raw_samples].map { |_, w| w }.max || 0
    assert_operator max_weight2, :<, 200_000_000,
      "Surviving thread's max weight (#{max_weight2}ns) should not include inter-session gap"
  end

  def test_frame_table_growth
    Rperf.start(frequency: 1000)
    deep_recurse(200) { busy_wait(2.0) }
    data = Rperf.stop

    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  # --- Input validation ---

  def test_frequency_zero_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 0) }
  end

  def test_frequency_negative_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: -1) }
  end

  def test_frequency_non_integer_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 1.5) }
  end

  def test_frequency_too_high_raises
    assert_raise(ArgumentError) { Rperf.start(frequency: 10_001) }
  end

  if RUBY_PLATFORM =~ /linux/
    def test_signal_kill_raises
      assert_raise(ArgumentError) { Rperf.start(signal: 9) }
    end

    def test_signal_stop_raises
      assert_raise(ArgumentError) { Rperf.start(signal: Signal.list["STOP"]) }
    end

    def test_signal_string_kill_raises
      assert_raise(ArgumentError) { Rperf.start(signal: "9") }
    end
  else
    def test_signal_not_supported
      assert_raise(ArgumentError) { Rperf.start(signal: 34) }
    end
  end

  def test_signal_false_ok
    data = Rperf.start(frequency: 500, signal: false) do
      5_000_000.times { 1 + 1 }
    end
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  # --- verbose mode ---

  def test_verbose_output
    old_stderr = $stderr
    $stderr = StringIO.new
    begin
      Rperf.start(frequency: 500, verbose: true)
      5_000_000.times { 1 + 1 }
      Rperf.stop

      output = $stderr.string
    ensure
      $stderr = old_stderr
    end

    assert_include output, "[Rperf] mode="
    assert_include output, "[Rperf] sampling:"
    assert_include output, "[Rperf] samples recorded:"
  end

  def test_verbose_top_tables
    old_stderr = $stderr
    $stderr = StringIO.new
    begin
      Rperf.start(frequency: 1000, verbose: true)
      10_000_000.times { 1 + 1 }
      Rperf.stop

      output = $stderr.string
    ensure
      $stderr = old_stderr
    end

    assert_include output, "[Rperf] top"
    assert_include output, "by flat:"
    assert_include output, "by cum:"
  end

  # --- wall mode ---

  def test_wall_mode_basic
    data = Rperf.start(frequency: 500, mode: :wall) do
      5_000_000.times { 1 + 1 }
    end
    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
    assert_valid_samples(data[:aggregated_samples])
  end

  def test_wall_mode_sleep_weight
    data = Rperf.start(frequency: 500, mode: :wall, aggregate: false) do
      sleep 0.1
    end
    assert_not_nil data
    samples = data[:raw_samples]
    assert_operator samples.size, :>, 0

    total_weight = samples.sum { |_, w| w }
    # Wall mode with 100ms sleep should have at least ~50ms total weight
    assert_operator total_weight, :>, 50_000_000,
      "Wall mode total weight (#{total_weight}ns) should reflect sleep time"
  end

  # --- Session cleanup on stop ---

  def test_session_cleanup_on_stop
    Rperf.start(frequency: 100, inherit: :fork)
    assert_not_nil ENV["RPERF_SESSION_DIR"], "inherit: :fork should set RPERF_SESSION_DIR"
    sleep 0.02
    Rperf.stop

    assert_nil ENV["RPERF_SESSION_DIR"],
      "RPERF_SESSION_DIR should be nil after stop"
    assert_nil ENV["RPERF_ROOT_PROCESS"],
      "RPERF_ROOT_PROCESS should be nil after stop"

    # A second start/stop cycle should work without error
    Rperf.start(frequency: 100, inherit: :fork)
    assert_not_nil ENV["RPERF_SESSION_DIR"]
    sleep 0.02
    data = Rperf.stop
    assert_not_nil data, "Second session should return data"
    assert_nil ENV["RPERF_SESSION_DIR"],
      "RPERF_SESSION_DIR should be nil after second stop"
    assert_nil ENV["RPERF_ROOT_PROCESS"],
      "RPERF_ROOT_PROCESS should be nil after second stop"
  end

  def test_consecutive_inherit_sessions
    2.times do |i|
      Rperf.start(frequency: 100, inherit: :fork)
      sleep 0.05
      data = Rperf.stop
      assert_not_nil data, "Session #{i} should return data"
    end
  end

  # --- inherit: true ENV restoration ---

  def test_inherit_true_restores_env_on_stop
    original_rubyopt = ENV["RUBYOPT"]
    original_enabled = ENV["RPERF_ENABLED"]
    original_rubylib = ENV["RUBYLIB"]

    Rperf.start(frequency: 100, inherit: true)
    # ENV should be modified while profiling
    assert_include ENV["RUBYOPT"].to_s, "-rrperf",
      "RUBYOPT should contain -rrperf while profiling with inherit: true"
    assert_equal "1", ENV["RPERF_ENABLED"]

    sleep 0.02
    Rperf.stop

    # ENV should be restored after stop
    assert_equal original_rubyopt, ENV["RUBYOPT"],
      "RUBYOPT should be restored after stop"
    assert_equal original_enabled, ENV["RPERF_ENABLED"],
      "RPERF_ENABLED should be restored after stop"
    assert_equal original_rubylib, ENV["RUBYLIB"],
      "RUBYLIB should be restored after stop"
  end

  def test_inherit_true_no_rubyopt_duplication
    original_rubyopt = ENV["RUBYOPT"]

    # Two start/stop cycles should not accumulate -rrperf
    2.times do
      Rperf.start(frequency: 100, inherit: true)
      sleep 0.02
      Rperf.stop
    end

    assert_equal original_rubyopt, ENV["RUBYOPT"],
      "RUBYOPT should not accumulate -rrperf across start/stop cycles"
  end

  # --- ActiveJob middleware require ---

  def test_active_job_middleware_loadable
    has_active_support = begin
      require "active_support/concern"
      true
    rescue LoadError
      false
    end
    omit "active_support not available" unless has_active_support

    require "rperf/active_job"
    assert defined?(Rperf::ActiveJobMiddleware),
      "Rperf::ActiveJobMiddleware should be defined after require"
  end
end
