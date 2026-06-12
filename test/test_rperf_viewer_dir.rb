require_relative "test_helper"
require "rperf/viewer"
require "open3"
require "json"
require "tmpdir"
require "socket"

# Phase 2: time-travel viewer — directory snapshots, lazy loading,
# meta/summary in list responses, unified take_snapshot! format.
class TestRperfViewerDir < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  def setup
    @viewer = Rperf::Viewer.new(nil, path: "")
  end

  def teardown
    ENV.delete("RPERF_META_GIT")
    ENV.delete("RPERF_META_LABELS")
    super
  end

  private

  def rack_env(path)
    { "PATH_INFO" => path, "REQUEST_METHOD" => "GET" }
  end

  def json_get(path)
    status, _headers, body = @viewer.call(rack_env(path))
    raise "GET #{path} -> #{status}: #{body[0]}" unless status == 200
    JSON.parse(body[0])
  end

  def write_profile(path, sha: nil, branch: "main", committed_at: nil, created_at: nil,
                    allocated: 1000, samples: nil)
    samples ||= [[[["app.rb", "Object#work"]], 1_000_000, 0, 0]]
    meta = { format_version: 1, ruby_version: RUBY_VERSION, rperf_version: Rperf::VERSION,
             mode: "cpu" }
    meta[:created_at] = created_at if created_at
    if sha
      git = { sha: sha, branch: branch, subject: "Commit #{sha[0, 7]}", dirty: false }
      git[:committed_at] = committed_at if committed_at
      meta[:git] = git
    end
    summary = { total_ms: 1.0, samples: 1, allocated_objects: allocated,
                gc_count_minor: 1, gc_count_major: 0, top_methods: [] }
    data = { meta: meta, summary: summary, mode: "cpu", frequency: 100,
             duration_ns: 1_000_000, sampling_count: 1, aggregated_samples: samples }
    Rperf.save(path, data, format: :json)
  end

  def write_old_profile(path)
    data = { mode: "cpu", frequency: 100, duration_ns: 1_000_000, sampling_count: 1,
             aggregated_samples: [[[["old.rb", "Object#old"]], 1_000_000, 0, 0]],
             rperf_version: Rperf::VERSION }
    File.binwrite(path, Rperf.gzip(JSON.generate(data)))
  end

  public

  # --- add_snapshot_dir ---

  def test_directory_listing_sorted_by_committed_at
    Dir.mktmpdir do |dir|
      # written in reverse order to prove sorting is by committed_at, not name/mtime
      write_profile(File.join(dir, "c.json.gz"), sha: "c" * 40, committed_at: "2026-06-11T00:00:00Z")
      write_profile(File.join(dir, "a.json.gz"), sha: "a" * 40, committed_at: "2026-06-09T00:00:00Z")
      write_profile(File.join(dir, "b.json.gz"), sha: "b" * 40, committed_at: "2026-06-10T00:00:00Z")

      assert_equal 3, @viewer.add_snapshot_dir(dir)
      list = json_get("/snapshots")
      shas = list.map { |s| s.dig("meta", "git", "sha")[0] }
      assert_equal %w[a b c], shas, "sorted oldest to newest by committed_at"
      assert_equal [1, 2, 3], list.map { |s| s["id"] }
      assert_kind_of Hash, list[0]["summary"]
      assert_equal 1000, list[0]["summary"]["allocated_objects"]
      assert_kind_of String, list[0]["file"]
    end
  end

  def test_directory_includes_old_format_as_unknown
    Dir.mktmpdir do |dir|
      write_profile(File.join(dir, "new.json.gz"), sha: "a" * 40, committed_at: "2026-06-09T00:00:00Z")
      write_old_profile(File.join(dir, "old.json.gz"))

      assert_equal 2, @viewer.add_snapshot_dir(dir)
      list = json_get("/snapshots")
      unknown = list.find { |s| s["meta"].nil? }
      assert_not_nil unknown, "old-format file should be listed without meta"
      assert_equal "old.json.gz", unknown["file"]
    end
  end

  def test_directory_lazy_body_load
    Dir.mktmpdir do |dir|
      write_profile(File.join(dir, "p.json.gz"), sha: "a" * 40)
      @viewer.add_snapshot_dir(dir)
      id = json_get("/snapshots")[0]["id"]
      detail = json_get("/snapshots/#{id}")
      assert_equal [["Object#work"]], detail["samples"].map { |s| s["stack"] }
      assert_equal "a" * 40, detail.dig("meta", "git", "sha")
      assert_kind_of Hash, detail["summary"]
    end
  end

  def test_directory_lazy_body_load_old_format
    Dir.mktmpdir do |dir|
      write_old_profile(File.join(dir, "old.json.gz"))
      @viewer.add_snapshot_dir(dir)
      id = json_get("/snapshots")[0]["id"]
      detail = json_get("/snapshots/#{id}")
      assert_equal [["Object#old"]], detail["samples"].map { |s| s["stack"] }
      assert_nil detail["meta"]
    end
  end

  def test_directory_corrupt_body_returns_500
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "junk.json.gz"), "not really gzip")
      @viewer.add_snapshot_dir(dir)
      id = json_get("/snapshots")[0]["id"]
      status, _h, _b = @viewer.call(rack_env("/snapshots/#{id}"))
      assert_equal 500, status
    end
  end

  def test_directory_listing_tolerates_corrupt_deflate_body
    # Valid gzip header + corrupt deflate stream (Zlib::DataError) — one bad
    # snapshot must not crash the listing of the whole directory
    Dir.mktmpdir do |dir|
      write_profile(File.join(dir, "good.json.gz"), sha: "a" * 40)
      bytes = File.binread(File.join(dir, "good.json.gz"))
      bytes[12, 16] = "\x00" * 16
      File.binwrite(File.join(dir, "bad.json.gz"), bytes)
      assert_equal 2, @viewer.add_snapshot_dir(dir)
      list = json_get("/snapshots")
      assert_equal 2, list.size
      # The corrupt one is listed as unknown (no meta); the good one keeps its meta
      assert_equal 1, list.count { |s| s["meta"] }
    end
  end

  def test_directory_ignores_max_snapshots
    Dir.mktmpdir do |dir|
      viewer = Rperf::Viewer.new(nil, path: "", max_snapshots: 2)
      5.times do |i|
        write_profile(File.join(dir, "p#{i}.json.gz"), sha: format("%040x", i),
                      committed_at: "2026-06-0#{i + 1}T00:00:00Z")
      end
      assert_equal 5, viewer.add_snapshot_dir(dir)
      status, _h, body = viewer.call(rack_env("/snapshots"))
      assert_equal 200, status
      assert_equal 5, JSON.parse(body[0]).size
    end
  end

  def test_directory_listing_100_snapshots_is_fast
    Dir.mktmpdir do |dir|
      # bulky body to prove the body is not parsed during listing
      samples = 200.times.map { |i| [[["app.rb", "Object#m#{i}"], ["app.rb", "main"]], 1000 + i, 0, 0] }
      100.times do |i|
        write_profile(File.join(dir, "p#{format('%03d', i)}.json.gz"),
                      sha: format("%040x", i),
                      committed_at: format("2026-01-01T%02d:%02d:00Z", i / 60, i % 60),
                      samples: samples)
      end
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 100, @viewer.add_snapshot_dir(dir)
      list = json_get("/snapshots")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      assert_equal 100, list.size
      assert_operator elapsed, :<, 1.0, "listing 100 snapshots should take < 1s (took #{elapsed.round(2)}s)"
    end
  end

  # --- in-memory snapshots (Rack viewer integration) ---

  def test_add_snapshot_attaches_meta_and_summary
    data = { mode: :wall, frequency: 100, duration_ns: 5_000_000, sampling_count: 3,
             aggregated_samples: [[[["app.rb", "Object#req"]], 5_000_000, 0, 0]] }
    @viewer.add_snapshot(data)
    list = json_get("/snapshots")
    assert_equal 1, list[0].dig("meta", "format_version")
    assert_equal 5.0, list[0].dig("summary", "total_ms")
    detail = json_get("/snapshots/1")
    assert_equal 1, detail.dig("meta", "format_version")
  end

  def test_take_snapshot_includes_gc_stats
    Rperf.start(frequency: 1000, mode: :cpu, inherit: false)
    busy_wait(0.02)
    entry = @viewer.take_snapshot!
    Rperf.stop
    assert_not_nil entry
    summary = entry[:data][:summary]
    assert_kind_of Integer, summary[:allocated_objects]
    assert_kind_of Integer, summary[:gc_count_minor]
  end

  # --- viewer HTML ---

  def test_html_contains_sidebar_and_data_source_hook
    status, _h, body = @viewer.call(rack_env("/"))
    assert_equal 200, status
    html = body[0]
    assert_include html, 'id="sidebar"'
    assert_include html, 'id="snapshot-list"'
    assert_include html, "RPERF_DATA_SOURCE"
    assert_include html, "onAuthError"
    assert_include html, "loadSnapshotList().catch(showLoadError);"
  end

  def test_static_html_still_renders
    data = { mode: :cpu, frequency: 100, duration_ns: 1_000_000, sampling_count: 1,
             aggregated_samples: [[[["app.rb", "Object#work"]], 1_000_000, 0, 0]] }
    html = Rperf::Viewer.render_static_html(data)
    assert_include html, "currentData = {"
    assert_not_include html, "loadSnapshotList().catch"
    assert_include html, 'id="lbl-snapshot" style="display:none"'
  end

  def test_static_html_preserves_backslashes
    # String-replacement sub would eat one level of backslash escaping
    data = { mode: :cpu, frequency: 100, duration_ns: 1_000_000, sampling_count: 1,
             aggregated_samples: [[[["C:\\Users\\app.rb", "Object#work"]], 1_000_000, 0, 1]],
             label_sets: [{}, { dir: "C:\\Users" }] }
    html = Rperf::Viewer.render_static_html(data)
    assert_include html, '"C:\\\\Users"'
  end

  # --- CLI ---

  def test_cli_report_empty_directory
    Dir.mktmpdir do |dir|
      cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, "report", dir]
      _, stderr, status = Open3.capture3(*cmd)
      refute_equal 0, status.exitstatus
      assert_include stderr, "No .json"
    end
  end

  def test_cli_report_directory_rejects_other_modes
    Dir.mktmpdir do |dir|
      write_profile(File.join(dir, "p.json.gz"), sha: "a" * 40)
      cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, "report", "--top", dir]
      _, stderr, status = Open3.capture3(*cmd)
      refute_equal 0, status.exitstatus
      assert_include stderr, "time-travel viewer"
    end
  end

  def test_cli_report_port_out_of_range
    _, stderr, status = Open3.capture3(RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE,
                                       "report", "--port", "99999", "x.json.gz")
    refute_equal 0, status.exitstatus
    assert_include stderr, "--port must be 1..65535"
  end

  def test_cli_report_serves_on_given_port_and_host
    Dir.mktmpdir do |dir|
      write_profile(File.join(dir, "p.json.gz"), sha: "a" * 40)
      port = nil
      TCPServer.open("localhost", 0) { |s| port = s.addr[1] }
      cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE,
             "report", "--port", port.to_s, "--host", "127.0.0.1", dir]
      # rackup/webrick come from the Gemfile (development group), so keep
      # the bundler environment for the child
      errlog = File.join(dir, "server.log")
      env = { "DISPLAY" => nil, "WAYLAND_DISPLAY" => nil }
      pid = spawn(env, *cmd, out: File::NULL, err: errlog)
      begin
        body = nil
        last_error = nil
        50.times do
          require "net/http"
          begin
            body = Net::HTTP.get(URI("http://127.0.0.1:#{port}/snapshots"))
            break
          rescue StandardError => e
            last_error = e
            sleep 0.1
          end
        end
        server_log = File.exist?(errlog) ? File.read(errlog) : "(no log)"
        assert_not_nil body,
          "viewer should respond on --port #{port} (last error: #{last_error.inspect})\nserver log:\n#{server_log}"
        assert_equal 1, JSON.parse(body).size
      ensure
        Process.kill(:TERM, pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
