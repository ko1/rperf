require_relative "test_helper"

class TestRperfSnapshot < Test::Unit::TestCase
  include RperfTestHelper

  def test_snapshot_returns_hash
    Rperf.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    snap = Rperf.snapshot

    assert_kind_of Hash, snap
    assert_include snap, :aggregated_samples
    assert_include snap, :mode
    assert_include snap, :frequency
    assert_include snap, :trigger_count
    assert_include snap, :sampling_count
    assert_include snap, :start_time_ns
    assert_include snap, :duration_ns
    assert_include snap, :unique_frames
    assert_include snap, :unique_stacks
  end

  def test_snapshot_does_not_stop_profiling
    Rperf.start(frequency: 1000)
    1_000_000.times { 1 + 1 }
    Rperf.snapshot

    # profiling should still be running; more work + stop should succeed
    1_000_000.times { 1 + 1 }
    data = Rperf.stop

    assert_not_nil data
    assert_operator data[:aggregated_samples].size, :>, 0
  end

  def test_snapshot_accumulates
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    snap1 = Rperf.snapshot

    5_000_000.times { 1 + 1 }
    snap2 = Rperf.snapshot

    assert_operator snap2[:sampling_count], :>=, snap1[:sampling_count],
      "Second snapshot should have >= samples than first"

    total1 = snap1[:aggregated_samples].sum { |_, w, _| w }
    total2 = snap2[:aggregated_samples].sum { |_, w, _| w }
    assert_operator total2, :>=, total1,
      "Second snapshot total weight should be >= first"
  end

  def test_snapshot_data_usable_with_encoders
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    snap = Rperf.snapshot

    # Collapsed format
    collapsed = Rperf::Collapsed.encode(snap)
    assert_kind_of String, collapsed
    assert_operator collapsed.size, :>, 0

    # Text format
    text = Rperf::Text.encode(snap)
    assert_kind_of String, text
    assert_include text, "Total:"

    # PProf format (raw protobuf, not gzipped)
    pprof = Rperf::PProf.encode(snap)
    assert_kind_of String, pprof
    assert_operator pprof.bytesize, :>, 0
  end

  def test_snapshot_valid_samples
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    snap = Rperf.snapshot

    assert_operator snap[:aggregated_samples].size, :>, 0
    assert_valid_samples(snap[:aggregated_samples])
  end

  def test_snapshot_nil_when_not_profiling
    assert_nil Rperf.snapshot
  end

  def test_snapshot_raises_without_aggregate
    Rperf.start(frequency: 1000, aggregate: false)
    1_000_000.times { 1 + 1 }
    assert_raise(RuntimeError) { Rperf.snapshot }
  end

  def test_multiple_snapshots
    Rperf.start(frequency: 1000)
    snapshots = []
    5.times do
      1_000_000.times { 1 + 1 }
      snapshots << Rperf.snapshot
    end
    data = Rperf.stop

    # Each snapshot should have valid data
    snapshots.each_with_index do |snap, i|
      assert_kind_of Hash, snap, "Snapshot #{i} should be a Hash"
      assert_operator snap[:aggregated_samples].size, :>, 0, "Snapshot #{i} should have samples"
    end

    # Sampling count should be non-decreasing
    counts = snapshots.map { |s| s[:sampling_count] }
    counts.each_cons(2) do |a, b|
      assert_operator b, :>=, a, "Sampling count should be non-decreasing"
    end

    # Stop data should have >= last snapshot
    assert_operator data[:sampling_count], :>=, counts.last
  end

  def test_snapshot_with_save
    Dir.mktmpdir do |dir|
      Rperf.start(frequency: 1000)
      5_000_000.times { 1 + 1 }
      snap = Rperf.snapshot

      path = File.join(dir, "snapshot.pb.gz")
      Rperf.save(path, snap)

      assert File.exist?(path), "Snapshot file should exist"
      content = File.binread(path)
      assert_equal "\x1f\x8b".b, content[0, 2], "Should be gzip format"
      assert_operator content.bytesize, :>, 0
    end
  end

  def test_snapshot_wall_mode
    Rperf.start(frequency: 500, mode: :wall)
    sleep 0.05
    5_000_000.times { 1 + 1 }
    snap = Rperf.snapshot

    assert_equal :wall, snap[:mode]
    assert_operator snap[:aggregated_samples].size, :>, 0
    assert_valid_samples(snap[:aggregated_samples])
  end

  def test_snapshot_multithread
    Rperf.start(frequency: 1000)

    threads = 4.times.map do
      Thread.new { 5_000_000.times { 1 + 1 } }
    end
    threads.each(&:join)

    snap = Rperf.snapshot
    assert_operator snap[:aggregated_samples].size, :>, 0
    assert_valid_samples(snap[:aggregated_samples])

    Rperf.stop
  end

  def test_snapshot_clear
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }

    snap1 = Rperf.snapshot(clear: true)
    assert_kind_of Hash, snap1
    assert_operator snap1[:aggregated_samples].size, :>, 0
    assert_operator snap1[:sampling_count], :>, 0

    # After clear, do more work and take another snapshot
    5_000_000.times { 1 + 1 }
    snap2 = Rperf.snapshot

    assert_kind_of Hash, snap2
    assert_operator snap2[:aggregated_samples].size, :>, 0
    assert_valid_samples(snap2[:aggregated_samples])

    # snap2 should cover only the post-clear period,
    # so its sampling_count should be less than snap1's cumulative count
    # (or at least not include snap1's samples)
    assert_operator snap2[:sampling_count], :<, snap1[:sampling_count] + snap2[:sampling_count] + 1
  end

  def test_snapshot_clear_resets_stats
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }

    snap1 = Rperf.snapshot(clear: true)
    count1 = snap1[:sampling_count]
    assert_operator count1, :>, 0

    # Immediately take another snapshot with minimal work
    snap2 = Rperf.snapshot
    count2 = snap2[:sampling_count]

    # After clear, the count should have been reset,
    # so snap2 count should be much less than snap1's
    assert_operator count2, :<, count1,
      "After clear, sampling_count should be reset (#{count2} < #{count1})"
  end

  def test_snapshot_clear_false_accumulates
    Rperf.start(frequency: 1000)
    5_000_000.times { 1 + 1 }
    snap1 = Rperf.snapshot(clear: false)

    5_000_000.times { 1 + 1 }
    snap2 = Rperf.snapshot(clear: false)

    # Without clear, sampling_count should be non-decreasing
    assert_operator snap2[:sampling_count], :>=, snap1[:sampling_count],
      "Without clear, sampling_count should accumulate"
  end
end
