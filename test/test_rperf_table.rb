require_relative "test_helper"
require "open3"
require "json"
require "tmpdir"

# Phase 1.5: flat table output for AI / machine consumption
# (report --format table / table-json, diff --format table / table-json).
class TestRperfTable < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  private

  def run_rperf(*args)
    cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, *args]
    stdout, stderr, status = Open3.capture3(*cmd)
    [stdout, stderr, status]
  end

  # Synthetic profile: leaf-first stacks, weights in ns
  def fake_data(stacks_with_weights, summary: nil)
    samples = stacks_with_weights.map do |stack, w|
      [stack.map { |name| ["app.rb", name] }, w, 0, 0]
    end
    total = stacks_with_weights.sum { |_, w| w }
    data = {
      mode: "cpu", frequency: 1000,
      duration_ns: total,
      sampling_count: samples.size,
      aggregated_samples: samples,
    }
    data[:summary] = summary if summary
    data
  end

  public

  # --- report rows ---

  def test_report_rows_columns_and_order
    data = fake_data([
      [%w[leaf mid root], 50_000_000],
      [%w[mid root],      30_000_000],
      [%w[root],          20_000_000],
    ])
    rows = Rperf::Table.report_rows(data)
    assert_equal %w[leaf mid root], rows.map { |r| r[:method] }
    assert_equal [50.0, 30.0, 20.0], rows.map { |r| r[:self_pct] }
    assert_equal [50.0, 80.0, 100.0], rows.map { |r| r[:total_pct] }
    assert_equal [50.0, 30.0, 20.0], rows.map { |r| r[:self_ms] }
  end

  def test_report_rows_other_aggregation
    stacks = (1..60).map { |i| [["m#{i}"], 1_000_000 * i] }
    rows = Rperf::Table.report_rows(fake_data(stacks))
    assert_equal 51, rows.size
    assert_equal "(other)", rows.last[:method]
    assert_nil rows.last[:total_pct]
    # the 10 smallest methods (m1..m10) fall into (other)
    expected_other_ms = (1..10).sum.to_f
    assert_in_delta expected_other_ms, rows.last[:self_ms], 0.5
  end

  def test_report_tsv_format
    data = fake_data([[%w[work], 100_000_000]])
    tsv = Rperf::Table.report_tsv(data)
    lines = tsv.lines
    assert_equal "method\tself_pct\ttotal_pct\tself_ms\n", lines[0]
    assert_equal "work\t100.0\t100.0\t100.0\n", lines[1]
    assert_match(/\A# summary\ttotal_ms=100\.0/, lines[2])
  end

  def test_report_tsv_uses_embedded_summary
    summary = { total_ms: 1234.5, allocated_objects: 999, gc_count_minor: 3, gc_count_major: 1 }
    data = fake_data([[%w[work], 100_000_000]], summary: summary)
    tsv = Rperf::Table.report_tsv(data)
    assert_include tsv, "total_ms=1234.5"
    assert_include tsv, "allocated_objects=999"
    assert_include tsv, "gc_count_minor=3"
  end

  def test_report_json_format
    data = fake_data([[%w[work], 100_000_000]])
    arr = JSON.parse(Rperf::Table.report_json(data), symbolize_names: true)
    assert_kind_of Array, arr
    assert_equal "work", arr[0][:method]
    assert_kind_of Hash, arr.last[:summary]
    assert_equal 100.0, arr.last[:summary][:total_ms]
  end

  # --- diff rows ---

  def test_diff_rows_delta_order
    base = fake_data([
      [%w[stable], 50_000_000],
      [%w[shrunk], 50_000_000],
    ])
    head = fake_data([
      [%w[stable], 50_000_000],
      [%w[shrunk], 10_000_000],
      [%w[grown],  40_000_000],
    ])
    rows = Rperf::Table.diff_rows(base, head)
    # |delta| descending; equal |delta| (grown +40 / shrunk -40) ties break by name
    assert_equal %w[grown shrunk stable], rows.map { |r| r[:method] }
    shrunk = rows[1]
    assert_equal 50.0, shrunk[:self_pct_base]
    assert_equal 10.0, shrunk[:self_pct_head]
    assert_equal(-40.0, shrunk[:delta_pt])
    grown = rows[0]
    assert_equal 0.0, grown[:self_pct_base]
    assert_equal 40.0, grown[:delta_pt]
  end

  def test_diff_summary_deltas
    base = fake_data([[%w[w], 1_000_000]],
                     summary: { total_ms: 100.0, allocated_objects: 1000, gc_count_minor: 2, gc_count_major: 0 })
    head = fake_data([[%w[w], 1_000_000]],
                     summary: { total_ms: 150.0, allocated_objects: 1500, gc_count_minor: 5, gc_count_major: 1 })
    s = Rperf::Table.diff_summary(base, head)
    assert_equal 50.0, s[:total_ms_delta]
    assert_equal 500, s[:allocated_objects_delta]
    assert_equal 3, s[:gc_count_minor_delta]
    assert_equal 1, s[:gc_count_major_delta]
  end

  def test_diff_tsv_format
    base = fake_data([[%w[w], 1_000_000]])
    head = fake_data([[%w[w], 1_000_000]])
    tsv = Rperf::Table.diff_tsv(base, head)
    lines = tsv.lines
    assert_equal "method\tself_pct_base\tself_pct_head\tdelta_pt\n", lines[0]
    assert_equal "w\t100.0\t100.0\t0.0\n", lines[1]
    assert_match(/\A# summary\t/, lines[2])
  end

  # --- CLI ---

  def test_cli_report_format_table
    Dir.mktmpdir do |dir|
      out = File.join(dir, "p.json.gz")
      data = fake_data([[%w[leaf root], 60_000_000], [%w[root], 40_000_000]])
      Rperf.save(out, data)
      stdout, stderr, status = run_rperf("report", "--format", "table", out)
      assert_equal 0, status.exitstatus, "report failed: #{stderr}"
      lines = stdout.lines
      assert_equal "method\tself_pct\ttotal_pct\tself_ms\n", lines[0]
      assert_equal "leaf\t60.0\t60.0\t60.0\n", lines[1]
      assert_match(/\A# summary\t/, lines.last)
    end
  end

  def test_cli_report_format_table_json
    Dir.mktmpdir do |dir|
      out = File.join(dir, "p.json.gz")
      Rperf.save(out, fake_data([[%w[work], 100_000_000]]))
      stdout, stderr, status = run_rperf("report", "--format", "table-json", out)
      assert_equal 0, status.exitstatus, "report failed: #{stderr}"
      arr = JSON.parse(stdout)
      assert_equal "work", arr[0]["method"]
      assert arr.last.key?("summary")
    end
  end

  def test_cli_diff_format_table_without_go
    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.json.gz")
      b = File.join(dir, "b.json.gz")
      Rperf.save(a, fake_data([[%w[w], 100_000_000]]))
      Rperf.save(b, fake_data([[%w[w], 50_000_000], [%w[v], 50_000_000]]))
      stdout, stderr, status = run_rperf("diff", "--format", "table", a, b)
      assert_equal 0, status.exitstatus, "diff failed: #{stderr}"
      lines = stdout.lines
      assert_equal "method\tself_pct_base\tself_pct_head\tdelta_pt\n", lines[0]
      assert_include stdout, "v\t0.0\t50.0\t50.0"
      assert_match(/\A# summary\t/, lines.last)
    end
  end

  def test_cli_report_format_table_rejects_pprof
    Dir.mktmpdir do |dir|
      out = File.join(dir, "p.pb.gz")
      File.binwrite(out, "\x1f\x8b dummy")
      _, stderr, status = run_rperf("report", "--format", "table", out)
      refute_equal 0, status.exitstatus
      assert_include stderr, "--format table requires"
    end
  end

  def test_cli_report_format_invalid
    _, stderr, status = run_rperf("report", "--format", "bogus", "x.json.gz")
    refute_equal 0, status.exitstatus
    assert_include stderr, "invalid argument"
  end
end
