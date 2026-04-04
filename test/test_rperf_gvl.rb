require_relative "test_helper"

class TestRperfGvl < Test::Unit::TestCase
  include RperfTestHelper

  def test_gvl_blocked_labels_wall_mode
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = extract_vm_state_labels(data)
    has_blocked = labels.include?("GVL:blocked")
    has_wait = labels.include?("GVL:wait")

    assert has_blocked || has_wait,
      "Wall mode with sleep should produce %GVL blocked or wait labels"
  end

  def test_gvl_events_cpu_mode_no_labels
    Rperf.start(frequency: 100, mode: :cpu)

    threads = 4.times.map do
      Thread.new { 20.times { sleep 0.002 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    labels = extract_vm_state_labels(data)
    refute labels.include?("GVL:blocked"),
      "CPU mode should NOT produce %GVL blocked labels"
    refute labels.include?("GVL:wait"),
      "CPU mode should NOT produce %GVL wait labels"
  end

  def test_gvl_wait_weight_positive
    Rperf.start(frequency: 100, mode: :wall)

    threads = 4.times.map do
      Thread.new { 50.times { sleep 0.001 } }
    end
    threads.each(&:join)

    data = Rperf.stop
    assert_not_nil data

    label_sets = data[:label_sets] || []
    gvl_samples = data[:aggregated_samples].select { |_, _, _, label_set_id|
      ls = label_sets[label_set_id]
      ls && ls["%GVL"]
    }

    gvl_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GVL sample weight should be positive"
    end
  end

  # --- GC labels ---

  def test_gc_labels_wall_mode
    Rperf.start(frequency: 1000, mode: :wall)

    # Force GC repeatedly to generate GC samples
    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    labels = extract_vm_state_labels(data)
    has_gc_marking = labels.include?("GC:mark")
    has_gc_sweeping = labels.include?("GC:sweep")

    assert has_gc_marking || has_gc_sweeping,
      "Wall mode with forced GC should produce %GC mark or sweep labels"
  end

  def test_gc_labels_weight_positive
    Rperf.start(frequency: 1000, mode: :wall)

    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    label_sets = data[:label_sets] || []
    gc_samples = data[:aggregated_samples].select { |_, _, _, label_set_id|
      ls = label_sets[label_set_id]
      ls && ls["%GC"]
    }

    gc_samples.each do |_, weight|
      assert_operator weight, :>, 0, "GC sample weight should be positive"
    end
  end

  def test_gc_labels_cpu_mode_still_recorded
    # GC samples use wall time regardless of mode
    Rperf.start(frequency: 1000, mode: :cpu)

    arrays = []
    100.times do
      arrays << Array.new(10_000) { Object.new }
      arrays.shift if arrays.size > 5
      GC.start
    end

    data = Rperf.stop
    assert_not_nil data

    labels = extract_vm_state_labels(data)
    has_gc = labels.include?("GC:mark") || labels.include?("GC:sweep")
    # GC labels should be recorded even in CPU mode (they use wall time)
    assert has_gc,
      "CPU mode should still record GC samples (with wall time weight)"
  end

  private

  # Extract all %GVL and %GC label values from profiling data
  # Returns e.g. ["GVL:blocked", "GVL:wait", "GC:mark"]
  def extract_vm_state_labels(data)
    label_sets = data[:label_sets] || []
    result = []
    data[:aggregated_samples].each do |_, _, _, lsi|
      ls = label_sets[lsi]
      next unless ls
      gvl = ls[:"%GVL"] || ls["%GVL"]
      gc  = ls[:"%GC"]  || ls["%GC"]
      result << "GVL:#{gvl}" if gvl
      result << "GC:#{gc}" if gc
    end
    result.uniq
  end
end
