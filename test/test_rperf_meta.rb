require_relative "test_helper"
require "open3"
require "json"
require "tmpdir"

# Phase 1: meta/summary embedding, --label / --snapshot-dir, prefix reader.
class TestRperfMeta < Test::Unit::TestCase
  include RperfTestHelper

  RPERF_EXE = File.expand_path("../exe/rperf", __dir__)
  LIB_DIR = File.expand_path("../lib", __dir__)

  def teardown
    ENV.delete("RPERF_META_GIT")
    ENV.delete("RPERF_META_LABELS")
    super
  end

  private

  def run_rperf(*args, env: {}, chdir: nil)
    cmd = [RbConfig.ruby, "-I", LIB_DIR, RPERF_EXE, *args]
    # Isolate from any surrounding CI environment
    env = { "GITHUB_SHA" => nil, "GITHUB_REF_NAME" => nil, "GITHUB_HEAD_REF" => nil }.merge(env)
    opts = chdir ? { chdir: chdir } : {}
    stdout, stderr, status = Open3.capture3(env, *cmd, **opts)
    [stdout, stderr, status]
  end

  def profile_data
    Rperf.start(frequency: 1000, mode: :cpu, inherit: false) do
      busy_wait(0.05)
    end
  end

  def init_git_repo(dir, subject: "Test commit")
    system("git", "init", "-q", dir, exception: true)
    File.write(File.join(dir, "f.txt"), "x")
    system("git", "-C", dir, "add", "f.txt", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
           "commit", "-qm", subject, exception: true)
    IO.popen(["git", "-C", dir, "rev-parse", "HEAD"], &:read).strip
  end

  public

  # --- meta/summary generation (API) ---

  def test_save_attaches_meta_and_summary
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      loaded = Rperf.load(path)

      meta = loaded[:meta]
      assert_kind_of Hash, meta
      assert_equal 1, meta[:format_version]
      assert_equal RUBY_VERSION, meta[:ruby_version]
      assert_equal Rperf::VERSION, meta[:rperf_version]
      assert_equal "cpu", meta[:mode]
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, meta[:created_at])
      # Tests run inside the rperf repository → git info present
      assert_kind_of Hash, meta[:git]
      assert_match(/\A[0-9a-f]{40}\z/, meta[:git][:sha])
      assert_boolean meta[:git][:dirty]

      summary = loaded[:summary]
      assert_kind_of Hash, summary
      assert_operator summary[:total_ms], :>, 0
      assert_operator summary[:samples], :>, 0
      assert_kind_of Integer, summary[:gc_count_minor]
      assert_kind_of Integer, summary[:allocated_objects]
      assert_operator summary[:maxrss_mb], :>, 0
      assert_kind_of Array, summary[:top_methods]
      assert_operator summary[:top_methods].size, :<=, 50
      top = summary[:top_methods].first
      assert_kind_of String, top[:name]
      assert_kind_of Float, top[:self_pct]
      assert_kind_of Float, top[:total_pct]
      # sorted by self_pct descending
      pcts = summary[:top_methods].map { |m| m[:self_pct] }
      assert_equal pcts.sort.reverse, pcts
    end
  end

  def test_meta_env_null_omits_git
    ENV["RPERF_META_GIT"] = "null"
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      loaded = Rperf.load(path)
      assert_kind_of Hash, loaded[:meta]
      refute loaded[:meta].key?(:git), "git key should be omitted with RPERF_META_GIT=null"
    end
  end

  def test_meta_labels_from_env
    ENV["RPERF_META_LABELS"] = JSON.generate("ci" => "github-actions", "pr" => "123")
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      loaded = Rperf.load(path)
      assert_equal({ ci: "github-actions", pr: "123" }, loaded[:meta][:labels])
    end
  end

  def test_resave_preserves_existing_meta
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      loaded = Rperf.load(path)
      original_created_at = loaded[:meta][:created_at]
      path2 = File.join(dir, "p2.json.gz")
      Rperf.save(path2, loaded)
      reloaded = Rperf.load(path2)
      assert_equal original_created_at, reloaded[:meta][:created_at]
    end
  end

  # --- collect_git ---

  def test_collect_git_outside_repo
    Dir.mktmpdir do |dir|
      assert_nil Rperf::Meta.collect_git(dir)
    end
  end

  def test_collect_git_in_repo
    Dir.mktmpdir do |dir|
      sha = init_git_repo(dir, subject: "Meta test subject")
      git = Rperf::Meta.collect_git(dir)
      assert_equal sha, git[:sha]
      assert_equal "Meta test subject", git[:subject]
      assert_equal false, git[:dirty]
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, git[:committed_at])
      assert_kind_of String, git[:branch]

      File.write(File.join(dir, "dirty.txt"), "y")
      assert_equal true, Rperf::Meta.collect_git(dir)[:dirty]
    end
  end

  def test_collect_git_github_actions_priority
    Dir.mktmpdir do |dir|
      init_git_repo(dir)
      fake_sha = "f" * 40
      ENV["GITHUB_SHA"] = fake_sha
      ENV["GITHUB_REF_NAME"] = "feature/x"
      git = Rperf::Meta.collect_git(dir)
      assert_equal fake_sha, git[:sha]
      assert_equal "feature/x", git[:branch]
      assert_equal false, git[:dirty]
    end
  ensure
    ENV.delete("GITHUB_SHA")
    ENV.delete("GITHUB_REF_NAME")
  end

  # --- snapshot_filename ---

  def test_snapshot_filename
    t = Time.utc(2026, 6, 12, 10, 0, 0)
    git = { sha: "88e1a40deadbeef" }
    assert_equal "rperf-88e1a40-20260612T100000Z.json.gz",
                 Rperf::Meta.snapshot_filename(git, time: t)
    assert_equal "rperf-nogit-20260612T100000Z-123.json.gz",
                 Rperf::Meta.snapshot_filename(nil, time: t, pid: 123)
  end

  # --- read_meta (prefix reader) ---

  def test_read_meta_matches_full_load
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      head = Rperf.read_meta(path)
      loaded = Rperf.load(path)
      assert_equal loaded[:meta], head[:meta]
      assert_equal loaded[:summary], head[:summary]
    end
  end

  def test_read_meta_plain_json
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json")
      Rperf.save(path, data)
      head = Rperf.read_meta(path)
      assert_equal 1, head[:meta][:format_version]
    end
  end

  def test_read_meta_old_format_returns_nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.json.gz")
      old = { mode: "cpu", frequency: 100, aggregated_samples: [], rperf_version: Rperf::VERSION }
      File.binwrite(path, Rperf.gzip(JSON.generate(old)))
      assert_nil Rperf.read_meta(path)
    end
  end

  def test_read_meta_spans_multiple_chunks
    # A meta larger than one 64KB read chunk exercises the incremental scan
    ENV["RPERF_META_LABELS"] = JSON.generate("big" => "x" * (128 * 1024))
    data = profile_data
    Dir.mktmpdir do |dir|
      path = File.join(dir, "p.json.gz")
      Rperf.save(path, data)
      head = Rperf.read_meta(path)
      assert_equal 128 * 1024, head[:meta][:labels][:big].size
      assert_kind_of Hash, head[:summary]
    end
  end

  def test_read_meta_corrupt_file_returns_nil
    Dir.mktmpdir do |dir|
      path = File.join(dir, "junk.json.gz")
      File.binwrite(path, "not gzip at all")
      assert_nil Rperf.read_meta(path)
    end
  end

  # --- backward compatibility ---

  def test_load_old_format_without_meta
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.json.gz")
      old = { mode: "cpu", frequency: 100,
              aggregated_samples: [[[["app.rb", "Object#work"]], 1000, 0, 0]],
              rperf_version: Rperf::VERSION }
      File.binwrite(path, Rperf.gzip(JSON.generate(old)))
      loaded = Rperf.load(path)
      assert_nil loaded[:meta]
      assert_equal 1, loaded[:aggregated_samples].size
      # Text encoder still works on old data
      assert_include Rperf::Text.encode(loaded), "Object#work"
    end
  end

  # --- CLI ---

  def test_cli_record_meta_in_git_repo
    Dir.mktmpdir do |dir|
      sha = init_git_repo(dir, subject: "CLI meta test")
      out = File.join(dir, "out.json.gz")
      _, stderr, status = run_rperf("record", "-f", "200", "-o", out,
                                    "--label", "ci=local", "--label", "n=1",
                                    RbConfig.ruby, "-e", "100_000.times { 1 + 1 }",
                                    chdir: dir)
      assert_equal 0, status.exitstatus, "record failed: #{stderr}"
      head = Rperf.read_meta(out)
      assert_equal sha, head[:meta][:git][:sha]
      assert_equal "CLI meta test", head[:meta][:git][:subject]
      assert_equal({ ci: "local", n: "1" }, head[:meta][:labels])
      assert_kind_of Hash, head[:summary]
    end
  end

  def test_cli_record_meta_outside_git_repo
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out.json.gz")
      _, stderr, status = run_rperf("record", "-f", "200", "-o", out,
                                    RbConfig.ruby, "-e", "100_000.times { 1 + 1 }",
                                    chdir: dir)
      assert_equal 0, status.exitstatus, "record failed: #{stderr}"
      head = Rperf.read_meta(out)
      refute head[:meta].key?(:git), "git key should be absent outside a repo"
    end
  end

  def test_cli_snapshot_dir_in_git_repo
    Dir.mktmpdir do |dir|
      sha = init_git_repo(dir)
      _, stderr, status = run_rperf("record", "-f", "200", "--snapshot-dir", "snaps",
                                    RbConfig.ruby, "-e", "100_000.times { 1 + 1 }",
                                    chdir: dir)
      assert_equal 0, status.exitstatus, "record failed: #{stderr}"
      files = Dir.glob(File.join(dir, "snaps", "*.json.gz")).map { |f| File.basename(f) }
      assert_equal 1, files.size
      assert_match(/\Arperf-#{sha[0, 7]}-\d{8}T\d{6}Z\.json\.gz\z/, files[0])
    end
  end

  def test_cli_snapshot_dir_outside_git_repo
    Dir.mktmpdir do |dir|
      _, stderr, status = run_rperf("record", "-f", "200", "--snapshot-dir", "snaps",
                                    RbConfig.ruby, "-e", "100_000.times { 1 + 1 }",
                                    chdir: dir)
      assert_equal 0, status.exitstatus, "record failed: #{stderr}"
      files = Dir.glob(File.join(dir, "snaps", "*.json.gz")).map { |f| File.basename(f) }
      assert_equal 1, files.size
      assert_match(/\Arperf-nogit-\d{8}T\d{6}Z-\d+\.json\.gz\z/, files[0])
    end
  end

  def test_cli_snapshot_dir_conflicts_with_output
    Dir.mktmpdir do |dir|
      _, stderr, status = run_rperf("record", "--snapshot-dir", "snaps", "-o", "x.json.gz",
                                    "true", chdir: dir)
      refute_equal 0, status.exitstatus
      assert_include stderr, "mutually exclusive"
    end
  end

  def test_cli_label_invalid_format
    _, stderr, status = run_rperf("record", "--label", "novalue", "true")
    refute_equal 0, status.exitstatus
    assert_include stderr, "--label must be KEY=VALUE"
  end
end
