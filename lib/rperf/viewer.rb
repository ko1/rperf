require_relative "../rperf"
require "json"
require "time"

# Rack middleware that serves flamegraph visualizations of rperf snapshots.
#
# *Security note*: This middleware exposes profiling data without
# authentication. It is intended for development and staging environments.
# In production, place it behind an authenticated reverse proxy or restrict
# access by IP / VPN.
#
# Usage:
#   require "rperf/viewer"
#   use Rperf::Viewer                             # mount at /rperf (default)
#   use Rperf::Viewer, path: "/profiler"          # custom mount path
#   use Rperf::Viewer, max_snapshots: 12          # keep fewer snapshots
#
# Take snapshots periodically:
#   viewer = Rperf::Viewer.instance
#   viewer.take_snapshot!          # snapshot with clear: true
#   viewer.add_snapshot(data)      # or add pre-taken snapshot data
#
# Time-travel mode (multiple snapshots from a directory):
#   viewer.add_snapshot_dir("./profiles")   # *.json(.gz) files; lazy-loaded
#
# The UI fetches data from /snapshots (list with meta/summary only) and
# /snapshots/:id (full body). When more than one snapshot is present, a
# sidebar lists them with commit info and diff/pin/sparkline support.
class Rperf::Viewer
  @instance = nil

  class << self
    # Returns the most recently created Viewer instance.
    attr_reader :instance
  end

  attr_reader :max_snapshots, :path

  def initialize(app, path: "/rperf", max_snapshots: 24)
    raise ArgumentError, "max_snapshots must be a positive integer, got #{max_snapshots.inspect}" unless max_snapshots.is_a?(Integer) && max_snapshots > 0
    @app = app
    @path = path.chomp("/")
    @max_snapshots = max_snapshots
    # In-memory entries: {id:, taken_at:, data:}
    # Directory entries: {id:, taken_at:, path:, meta:, summary:} — body lazy-loaded
    @snapshots = []
    @mutex = Mutex.new
    @next_id = 0
    self.class.instance_variable_set(:@instance, self)
  end

  # Take a snapshot from the running profiler and store it.
  # Returns the snapshot entry or nil if profiler is not running.
  def take_snapshot!
    data = Rperf.snapshot(clear: true)
    return nil unless data
    add_snapshot(data)
  end

  # Add a pre-taken snapshot hash to the history.
  # Attaches meta/summary (phase-1 profile format) unless already present,
  # so in-memory snapshots and directory profiles share the same list UI.
  def add_snapshot(data)
    data[:meta] ||= Rperf::Meta.build_meta(data)
    data[:summary] ||= Rperf::Meta.build_summary(data)
    @mutex.synchronize do
      @next_id += 1
      entry = { id: @next_id, taken_at: Time.now, data: data }
      @snapshots << entry
      # Evict only in-memory snapshots: directory entries (time-travel mode)
      # are exempt from max_snapshots and hold no body memory anyway
      while @snapshots.count { |s| s[:data] } > @max_snapshots
        idx = @snapshots.index { |s| s[:data] }
        @snapshots.delete_at(idx)
      end
      entry
    end
  end

  # Add all *.json(.gz) profiles in dir as lazy-loaded snapshots
  # (time-travel mode). Only meta/summary are read up front (Rperf.read_meta);
  # bodies are loaded on selection. Files without meta (older rperf) are
  # listed as unknown snapshots. Entries are sorted by
  # meta.git.committed_at → meta.created_at → file mtime.
  # max_snapshots does not apply. Returns the number of files added.
  def add_snapshot_dir(dir)
    files = Dir.glob(File.join(dir, "*.json.gz")) + Dir.glob(File.join(dir, "*.json"))
    entries = files.filter_map do |file|
      head = Rperf.read_meta(file)
      meta = head && head[:meta]
      summary = head && head[:summary]
      # File may vanish between glob and stat — skip instead of aborting the
      # whole listing
      mtime = begin
        File.mtime(file)
      rescue SystemCallError
        next
      end
      { path: file, meta: meta, summary: summary, taken_at: mtime,
        sort_time: snapshot_sort_time(meta, mtime) }
    end
    entries.sort_by! { |e| e[:sort_time] }
    @mutex.synchronize do
      entries.each do |e|
        @next_id += 1
        @snapshots << { id: @next_id, taken_at: e[:taken_at], path: e[:path],
                        meta: e[:meta], summary: e[:summary] }
      end
    end
    entries.size
  end

  # Rack interface
  def call(env)
    req_path = env["PATH_INFO"] || "/"

    # Not our path — pass through to app
    if req_path == @path
      # Exact match: redirect to trailing slash
      return [301, { "location" => "#{@path}/" }, [""]]
    end
    unless req_path.start_with?("#{@path}/")
      return @app ? @app.call(env) : [404, { "content-type" => "text/plain" }, ["Not Found"]]
    end

    # Strip prefix to get sub-path
    sub_path = req_path[@path.size..]

    case sub_path
    when "/"
      serve_html
    when "/snapshots"
      serve_snapshot_list
    when %r{\A/snapshots/(\d+)\z}
      serve_snapshot($1.to_i)
    else
      [404, { "content-type" => "text/plain" }, ["Not Found"]]
    end
  end

  # Convert aggregated samples to JSON-friendly format.
  # Stack is stored top-to-bottom (leaf first) in C; reverse to root-first for flamegraph.
  # Label set keys are converted from symbols to strings for JSON.
  def self.samples_to_json(samples, label_sets)
    json_samples = samples.map do |frames, weight, _thread_seq, label_set_id|
      # thread_seq is intentionally omitted: the viewer UI never reads it,
      # and it would bloat the largest responses the viewer serves
      {
        stack: frames.reverse.map { |_, label| label },
        weight: weight,
        label_set_id: label_set_id || 0,
      }
    end
    json_label_sets = label_sets.map do |ls|
      ls.is_a?(Hash) ? ls.transform_keys(&:to_s) : ls
    end
    [json_samples, json_label_sets]
  end

  # Generate a self-contained static HTML file with inline snapshot data.
  # The HTML loads d3/d3-flamegraph from CDN but requires no server.
  # This is the one intentional exception to fetch-based data loading:
  # a static file has no server to fetch from.
  def self.render_static_html(data)
    samples = data[:aggregated_samples] || []
    label_sets = data[:label_sets] || []
    json_samples, json_label_sets = samples_to_json(samples, label_sets)

    json_snapshot = JSON.generate({
      id: 1,
      taken_at: Time.now.iso8601,
      mode: data[:mode],
      frequency: data[:frequency],
      duration_ns: data[:duration_ns],
      sampling_count: data[:sampling_count],
      meta: data[:meta],
      summary: data[:summary],
      samples: json_samples,
      label_sets: json_label_sets,
    })

    logo = LOGO_SVG.sub("<svg ", '<svg style="height:36px;width:auto" ')

    html = VIEWER_HTML.sub("<!-- LOGO -->") { logo }

    # Hide the snapshot selector including its "Snapshot:" label text
    # (single snapshot, no server)
    html = html.sub('<label id="lbl-snapshot">', '<label id="lbl-snapshot" style="display:none">')

    # Replace dynamic loading with inline data.
    # Escape for safe embedding in <script>:
    #  - "</" prevents closing </script> tag injection
    #  - U+2028/U+2029 are line terminators in JS but valid in JSON
    json_safe = json_snapshot
      .gsub("</", "<\\/")
      .gsub(" ", "\\u2028")
      .gsub(" ", "\\u2029")
    # Block form: the String-replacement form of sub interprets \\ and \&
    # in the replacement, corrupting JSON that contains backslashes
    html = html.sub("loadSnapshotList().catch(showLoadError);") {
      "currentData = #{json_safe}; updateTagDropdowns(); applyAndRender();"
    }

    html
  end

  private

  def snapshot_sort_time(meta, mtime)
    str = meta&.dig(:git, :committed_at) || meta&.dig(:created_at)
    return mtime unless str
    begin
      Time.iso8601(str)
    rescue ArgumentError
      mtime
    end
  end

  LOGO_SVG = begin
    path = File.expand_path("../../docs/logo.svg", __dir__)
    File.exist?(path) ? File.read(path).freeze : ""
  end

  VIEWER_HTML = File.read(File.expand_path("viewer/viewer.html", __dir__)).freeze

  def serve_html
    logo = LOGO_SVG
      .sub("<svg ", '<svg style="height:36px;width:auto" ')
    [200, {
      "content-type" => "text/html; charset=utf-8",
      "x-frame-options" => "DENY",
      "x-content-type-options" => "nosniff",
      "content-security-policy" => "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'self'; img-src data:; frame-ancestors 'none'",
    }, [VIEWER_HTML.sub("<!-- LOGO -->") { logo }]]
  end

  def serve_snapshot_list
    list = @mutex.synchronize do
      @snapshots.map do |s|
        data = s[:data]
        {
          id: s[:id],
          taken_at: s[:taken_at].iso8601,
          # scrub: one non-UTF8 filename must not make JSON.generate raise
          # and 500 the whole snapshot list
          file: s[:path] ? File.basename(s[:path]).dup.force_encoding(Encoding::UTF_8).scrub : nil,
          mode: data ? data[:mode] : s.dig(:meta, :mode),
          duration_ns: data && data[:duration_ns],
          sampling_count: data && data[:sampling_count],
          meta: data ? data[:meta] : s[:meta],
          summary: data ? data[:summary] : s[:summary],
        }
      end
    end
    json_response(list)
  end

  def serve_snapshot(id)
    entry = @mutex.synchronize { @snapshots.find { |s| s[:id] == id } }
    return [404, { "content-type" => "text/plain" }, ["Snapshot not found"]] unless entry

    data = entry[:data]
    if data.nil? && entry[:path]
      # Lazy-load directory entry; body is not retained server-side
      begin
        data = Rperf.load(entry[:path])
      rescue StandardError => e
        return [500, { "content-type" => "text/plain" }, ["Failed to load #{File.basename(entry[:path])}: #{e.message}"]]
      end
    end
    samples = data[:aggregated_samples] || []
    label_sets = data[:label_sets] || []
    json_samples, json_label_sets = self.class.samples_to_json(samples, label_sets)

    json_response({
      id: entry[:id],
      taken_at: entry[:taken_at].iso8601,
      mode: data[:mode],
      frequency: data[:frequency],
      duration_ns: data[:duration_ns],
      sampling_count: data[:sampling_count],
      meta: data[:meta] || entry[:meta],
      summary: data[:summary] || entry[:summary],
      samples: json_samples,
      label_sets: json_label_sets,
    })
  end

  def json_response(obj)
    [200, {
      "content-type" => "application/json; charset=utf-8",
      "x-content-type-options" => "nosniff",
    }, [JSON.generate(obj)]]
  end
end
