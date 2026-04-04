require_relative "test_helper"

class TestRperfFork < Test::Unit::TestCase
  include RperfTestHelper

  def test_fork_stops_profiling_in_child
    Rperf.start(frequency: 100)

    rd, wr = IO.pipe
    pid = fork do
      rd.close
      result = Rperf.stop
      wr.puts(result.nil? ? "nil" : "not_nil")

      Rperf.start(frequency: 100)
      1_000_000.times { 1 + 1 }
      data = Rperf.stop
      wr.puts(data.nil? ? "no_data" : "has_data")
      wr.close
    end

    wr.close
    lines = rd.read.split("\n")
    rd.close
    _, status = Process.waitpid2(pid)

    assert status.success?, "Child process should exit successfully"
    assert_equal "nil", lines[0], "Rperf.stop in child should return nil"
    assert_equal "has_data", lines[1], "New profiling session in child should work"

    1_000_000.times { 1 + 1 }
    data = Rperf.stop
    assert_not_nil data, "Parent profiling should still work after fork"
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_repeated_start_stop_then_fork_no_signal_death
    # Regression test: repeated start/stop cycles could leave a pending RT
    # signal that kills the process after fork (exit code 128+42).
    10.times do
      3.times do
        Rperf.start(frequency: 1000)
        200_000.times { 1 + 1 }
        Rperf.stop
      end

      rd, wr = IO.pipe
      pid = fork do
        rd.close
        result = Rperf.stop
        wr.puts(result.nil? ? "nil" : "non_nil")
        Rperf.start(frequency: 100)
        100_000.times { 1 + 1 }
        data = Rperf.stop
        wr.puts(data.nil? ? "no_data" : "has_data")
        wr.close
      end

      wr.close
      lines = rd.read.split("\n")
      rd.close
      _, status = Process.waitpid2(pid)

      assert status.success?, "Child killed by signal #{status.termsig} on iteration"
      assert_equal "nil", lines[0]
      assert_equal "has_data", lines[1]
    end
  end
end

class TestRperfMultiProcess < Test::Unit::TestCase
  include RperfTestHelper

  def setup
    require "tmpdir"
    require "fileutils"
    require "json"
    # Create a proper hierarchy: user_dir (0700) / session_dir (0700)
    @test_base = Dir.mktmpdir("rperf-test-base-")
    @user_dir = File.join(@test_base, "rperf-#{Process.uid}")
    Dir.mkdir(@user_dir, 0700)
    @session_dir = File.join(@user_dir, "rperf-test-session")
    Dir.mkdir(@session_dir, 0700)
  end

  def teardown
    super
    FileUtils.rm_rf(@test_base) if @test_base && File.directory?(@test_base)
    # Clean up env vars
    ENV.delete("RPERF_SESSION_DIR")
    ENV.delete("RPERF_ROOT_PROCESS")
  end

  def test_merge_into_combines_samples
    merged_samples = []
    merged_label_sets = [{}]

    data1 = {
      aggregated_samples: [[[["/a.rb", "A#a"]], 1000, 0, 0]],
      label_sets: [{}],
    }
    data2 = {
      aggregated_samples: [[[["/b.rb", "B#b"]], 2000, 0, 0]],
      label_sets: [{}],
    }

    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data1)
    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data2)

    assert_equal 2, merged_samples.size
    assert_equal 1000, merged_samples[0][1]
    assert_equal 2000, merged_samples[1][1]
    assert_equal 1, merged_label_sets.size  # only [{}], no duplicates
  end

  def test_merge_into_remaps_label_set_ids
    merged_samples = []
    merged_label_sets = [{}]

    data1 = {
      aggregated_samples: [[[["/a.rb", "A#a"]], 1000, 0, 1]],
      label_sets: [{}, { "%pid" => "100" }],
    }
    data2 = {
      aggregated_samples: [[[["/b.rb", "B#b"]], 2000, 0, 1]],
      label_sets: [{}, { "%pid" => "200" }],
    }

    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data1)
    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data2)

    assert_equal 3, merged_label_sets.size  # {}, {"%pid"=>"100"}, {"%pid"=>"200"}
    # data1's label_set_id 1 maps to merged 1
    assert_equal 1, merged_samples[0][3]
    # data2's label_set_id 1 maps to merged 2 (different pid)
    assert_equal 2, merged_samples[1][3]
  end

  def test_merge_into_deduplicates_label_sets
    merged_samples = []
    merged_label_sets = [{}]

    same_label = { "endpoint" => "/users" }
    data1 = {
      aggregated_samples: [[[["/a.rb", "A#a"]], 1000, 0, 1]],
      label_sets: [{}, same_label],
    }
    data2 = {
      aggregated_samples: [[[["/b.rb", "B#b"]], 2000, 0, 1]],
      label_sets: [{}, same_label.dup],
    }

    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data1)
    Rperf.send(:_merge_into, merged_samples, merged_label_sets, data2)

    assert_equal 2, merged_label_sets.size  # {}, {"endpoint"=>"/users"} (deduped)
    assert_equal 1, merged_samples[0][3]
    assert_equal 1, merged_samples[1][3]  # same label_set_id
  end

  def test_fork_with_session_dir
    # Simulate multi-process mode by setting env vars and using _fork hook
    ENV["RPERF_SESSION_DIR"] = @session_dir
    ENV["RPERF_ROOT_PROCESS"] = Process.pid.to_s

    Rperf.send(:_install_fork_hook)

    Rperf.start(frequency: 1000, mode: :wall)
    # Write root's output to session dir
    Rperf.instance_variable_set(:@output, File.join(@session_dir, "profile-#{Process.pid}.json.gz"))
    Rperf.instance_variable_set(:@format, :json)

    pid = fork do
      # _restart_in_child is called by _fork hook
      500_000.times { 1 + 1 }
      Rperf.stop
      exit!(0)
    end

    500_000.times { 1 + 1 }
    _, status = Process.waitpid2(pid)
    assert status.success?, "Child should exit successfully"

    Rperf.stop

    # Both root and child should have written profiles
    profiles = Dir.glob(File.join(@session_dir, "profile-*.json.gz"))
    assert_equal 2, profiles.size, "Should have 2 profile files (root + child)"

    # Load and verify each profile has data
    profiles.each do |f|
      data = Rperf.load(f)
      assert_not_nil data
      assert_not_nil data[:aggregated_samples]
      assert_not_nil data[:pid]
      assert_not_nil data[:ppid]
    end
  end

  def test_fork_child_gets_pid_label
    ENV["RPERF_SESSION_DIR"] = @session_dir
    ENV["RPERF_ROOT_PROCESS"] = Process.pid.to_s

    Rperf.send(:_install_fork_hook)
    Rperf.start(frequency: 1000, mode: :wall)
    Rperf.instance_variable_set(:@output, File.join(@session_dir, "profile-#{Process.pid}.json.gz"))
    Rperf.instance_variable_set(:@format, :json)

    child_pid = nil
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      wr.puts Process.pid.to_s
      wr.close
      500_000.times { 1 + 1 }
      Rperf.stop
      exit!(0)
    end
    wr.close
    child_pid = rd.read.strip.to_i
    rd.close

    _, status = Process.waitpid2(pid)
    assert status.success?

    Rperf.stop

    # Load child's profile and check for %pid label
    child_profile = File.join(@session_dir, "profile-#{child_pid}.json.gz")
    assert File.exist?(child_profile), "Child profile should exist"
    data = Rperf.load(child_profile)
    label_sets = data[:label_sets]
    assert_not_nil label_sets

    # Find a label set with %pid key
    pid_labels = label_sets.select { |ls| ls.key?(:"%pid") || ls.key?("%pid") }
    assert_operator pid_labels.size, :>, 0, "Child should have %pid label"
  end

  def test_aggregate_and_report_merges_profiles
    # Write two fake profile files to session dir
    require "json"

    data1 = {
      mode: :wall,
      frequency: 1000,
      aggregated_samples: [[[["/a.rb", "A#a"]], 5_000_000, 0, 0]],
      label_sets: [{}],
      trigger_count: 5,
      sampling_count: 5,
      sampling_time_ns: 100,
      rperf_version: Rperf::VERSION,
    }
    data2 = {
      mode: :wall,
      frequency: 1000,
      aggregated_samples: [[[["/b.rb", "B#b"]], 3_000_000, 0, 0]],
      label_sets: [{}],
      trigger_count: 3,
      sampling_count: 3,
      sampling_time_ns: 50,
      rperf_version: Rperf::VERSION,
    }

    write_profile = ->(name, data) {
      path = File.join(@session_dir, name)
      json = JSON.generate(data)
      File.binwrite(path, Rperf.send(:gzip, json))
    }

    write_profile.call("profile-100.json.gz", data1)
    write_profile.call("profile-101.json.gz", data2)

    # Set up for aggregation
    ENV["RPERF_SESSION_DIR"] = @session_dir
    ENV["RPERF_MODE"] = "wall"
    ENV["RPERF_FREQUENCY"] = "1000"

    output_file = File.join(Dir.tmpdir, "rperf-test-merged-#{$$}.json.gz")
    Rperf.instance_variable_set(:@_aggregate_output, output_file)
    Rperf.instance_variable_set(:@_aggregate_stat, false)
    Rperf.instance_variable_set(:@_aggregate_format, :json)

    Rperf._aggregate_and_report

    # Session dir should be cleaned up
    assert !File.directory?(@session_dir), "Session dir should be removed after aggregation"

    # But merged output should exist
    assert File.exist?(output_file), "Merged output should exist"
    merged = Rperf.load(output_file)

    assert_equal 2, merged[:aggregated_samples].size
    assert_equal 8, merged[:trigger_count]
    assert_equal 8, merged[:sampling_count]
    assert_equal 2, merged[:process_count]
  ensure
    File.delete(output_file) if output_file && File.exist?(output_file)
  end
end
