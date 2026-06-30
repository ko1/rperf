# Profile metadata support: git/host info collection, summary statistics,
# snapshot file naming, and a meta/summary prefix reader that lists profiles
# without loading the sample body.
#
# JSON profiles written by rperf >= 0.10 place "meta" and "summary" as the
# first two top-level keys, so Meta.read can decompress only the head of the
# file and stop as soon as both are extracted.

# NOTE: json is NOT required here. rperf loads via `ruby -rrperf` at interpreter
# boot, before the profiled app runs `bundler/setup`. Requiring json eagerly
# would activate the default json gem and then clash with a bundle that pins a
# different json (Gem::LoadError). json is used only at profile write/read time
# (after the app has set up its bundle), so each user requires it lazily.
require "time"
require "zlib"

module Rperf
  module Meta
    FORMAT_VERSION = 1
    TOP_METHODS_LIMIT = 50

    module_function

    # Collect git information for the profiled working directory.
    # GitHub Actions environment variables take priority over git commands
    # (CI checkouts may be detached or shallow). Returns a Hash with
    # sha/branch/subject/committed_at/dirty, or nil when not in a git
    # repository or git is unavailable.
    def collect_git(dir = Dir.pwd)
      gh_sha = ENV["GITHUB_SHA"]
      # Validate the sha shape: the value is passed to git as a positional
      # argument, and a crafted value starting with "-" would be parsed as
      # a git option
      if gh_sha && gh_sha.match?(/\A\h{7,64}\z/)
        git = { sha: gh_sha, dirty: false }
        branch = ENV["GITHUB_HEAD_REF"]
        branch = ENV["GITHUB_REF_NAME"] if branch.nil? || branch.empty?
        git[:branch] = branch if branch && !branch.empty?
        # Enrich from the local checkout when possible (may fail on shallow clones)
        subject = git_capture(dir, "log", "-1", "--format=%s", gh_sha)
        committed_at = git_capture(dir, "log", "-1", "--format=%cI", gh_sha)
        git[:subject] = subject if subject && !subject.empty?
        git[:committed_at] = committed_at if committed_at && !committed_at.empty?
        return git
      end

      sha = git_capture(dir, "rev-parse", "HEAD")
      return nil if sha.nil? || sha.empty?

      git = { sha: sha }
      branch = git_capture(dir, "rev-parse", "--abbrev-ref", "HEAD")
      git[:branch] = branch if branch && !branch.empty? && branch != "HEAD"
      subject = git_capture(dir, "log", "-1", "--format=%s")
      git[:subject] = subject if subject && !subject.empty?
      committed_at = git_capture(dir, "log", "-1", "--format=%cI")
      git[:committed_at] = committed_at if committed_at && !committed_at.empty?
      status = git_capture(dir, "status", "--porcelain")
      git[:dirty] = !status.empty? if status
      git
    end

    # Run a git command, returning stripped stdout or nil on failure
    # (no git binary, not a repository, etc.).
    def git_capture(dir, *args)
      out = IO.popen(["git", "-C", dir, *args], err: File::NULL, &:read)
      $?.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    # File name used by `rperf record --snapshot-dir`.
    # In a git repository: rperf-<sha7>-<timestamp>.json.gz
    # Outside:            rperf-nogit-<timestamp>-<pid>.json.gz
    def snapshot_filename(git, time: Time.now.utc, pid: Process.pid)
      ts = time.utc.strftime("%Y%m%dT%H%M%SZ")
      if git && git[:sha]
        "rperf-#{git[:sha][0, 7]}-#{ts}.json.gz"
      else
        "rperf-nogit-#{ts}-#{pid}.json.gz"
      end
    end

    # Build the meta hash for a profile about to be written.
    # Git info comes from RPERF_META_GIT (set by the CLI, which collects it
    # before exec so a chdir in the profiled app cannot point at the wrong
    # repository); when unset (direct API usage) it is collected here.
    # RPERF_META_GIT="null" means "already checked, not a repository".
    def build_meta(data)
      meta = {
        format_version: FORMAT_VERSION,
        created_at: Time.now.utc.iso8601,
        ruby_version: RUBY_VERSION,
        rperf_version: Rperf::VERSION,
        mode: (data[:mode] || :cpu).to_s,
      }
      hostname = safe_hostname
      meta[:hostname] = hostname if hostname
      git = git_from_env_or_collect
      meta[:git] = git if git
      labels = labels_from_env
      meta[:labels] = labels if labels && !labels.empty?
      meta
    end

    def git_from_env_or_collect
      if ENV.key?("RPERF_META_GIT")
        v = ENV["RPERF_META_GIT"].to_s
        return nil if v.empty? || v == "null"
        begin
          require "json"
          JSON.parse(v, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end
      else
        # Memoized (array wraps a legitimate nil): periodic viewer snapshots
        # must not spawn git subprocesses on every take_snapshot!
        @collect_git_memo ||= [collect_git]
        @collect_git_memo[0]
      end
    end

    def labels_from_env
      v = ENV["RPERF_META_LABELS"]
      return nil unless v
      begin
        require "json"
        labels = JSON.parse(v)
        labels.is_a?(Hash) ? labels : nil
      rescue JSON::ParserError
        nil
      end
    end

    def safe_hostname
      require "socket"
      Socket.gethostname
    rescue StandardError
      nil
    end

    # Build the summary hash from profile data (as returned by Rperf.stop).
    # Fields whose source data is missing are omitted.
    def build_summary(data)
      s = {}
      s[:total_ms] = (data[:duration_ns] / 1e6).round(1) if data[:duration_ns]
      if data[:user_ns] || data[:sys_ns]
        s[:cpu_ms] = (((data[:user_ns] || 0) + (data[:sys_ns] || 0)) / 1e6).round(1)
      end
      if (gc = data[:gc_stats])
        s[:gc_count_minor] = gc[:minor_count] if gc[:minor_count]
        s[:gc_count_major] = gc[:major_count] if gc[:major_count]
        s[:gc_ms] = gc[:time_ms].to_f.round(1) if gc[:time_ms]
        s[:allocated_objects] = gc[:allocated_objects] if gc[:allocated_objects]
        s[:freed_objects] = gc[:freed_objects] if gc[:freed_objects]
      end
      s[:maxrss_mb] = data[:maxrss_mb] if data[:maxrss_mb]
      s[:samples] = data[:sampling_count] if data[:sampling_count]
      s[:top_methods] = top_methods(data)
      s
    end

    # Top methods by self time, merged by method name (shares the by-name
    # fold with Table so report/summary numbers can never diverge).
    def top_methods(data, limit: TOP_METHODS_LIMIT)
      samples = data[:aggregated_samples]
      return [] if !samples || samples.empty?

      flat_by_name, cum_by_name, total = Table.flat_cum_by_name(data)
      return [] if total <= 0

      flat_by_name.sort_by { |_, w| -w }.first(limit).map do |name, w|
        {
          name: name,
          self_pct: (w * 100.0 / total).round(1),
          total_pct: (cum_by_name[name] * 100.0 / total).round(1),
        }
      end
    end

    # --- meta/summary prefix reader ---

    READ_CHUNK = 64 * 1024
    READ_LIMIT = 8 * 1024 * 1024

    # Read meta/summary from a .json(.gz) profile without loading the body.
    # Returns { meta: Hash|nil, summary: Hash|nil } or nil for files without
    # leading meta/summary keys (old format) and unreadable/corrupt files.
    def read(path)
      File.open(path, "rb") do |f|
        magic = f.read(2)
        f.rewind
        io = (magic == "\x1f\x8b".b) ? Zlib::GzipReader.new(f) : f
        begin
          buf = "".b
          loop do
            chunk = io.read(READ_CHUNK)
            buf << chunk if chunk
            result = scan_prefix(buf)
            return result unless result == :incomplete
            return nil if chunk.nil? || buf.bytesize > READ_LIMIT
          end
        ensure
          # Free the inflate zstream now — directory listings open many files
          # and the buffers would otherwise linger until GC
          io.close if io.is_a?(Zlib::GzipReader)
        end
      end
    rescue Zlib::Error, SystemCallError, JSON::ParserError
      # Zlib::Error covers GzipFile::Error (truncated) and also DataError /
      # BufError (valid gzip header, corrupt deflate body) — one corrupt
      # snapshot must not break listing an entire directory
      nil
    end

    # Byte codes used by the scanner. Byte-wise scanning is safe in UTF-8:
    # continuation bytes are >= 0x80 and never collide with ASCII syntax.
    DQUOTE = 0x22
    BSLASH = 0x5c
    LBRACE = 0x7b
    RBRACE = 0x7d
    LBRACKET = 0x5b
    RBRACKET = 0x5d
    COMMA = 0x2c
    COLON = 0x3a

    # Scan the head of a JSON object for top-level "meta" / "summary" keys.
    # rperf writes them first, so scanning stops at the first other key —
    # large sample arrays are never traversed.
    # Returns { meta:, summary: }, nil (old format / malformed),
    # or :incomplete (need more input).
    def scan_prefix(buf)
      require "json" # lazy: see the note at the top of this file
      n = buf.bytesize
      i = skip_ws(buf, 0, n)
      return :incomplete if i >= n
      return nil unless buf.getbyte(i) == LBRACE
      i += 1
      found = {}

      loop do
        i = skip_ws(buf, i, n)
        return :incomplete if i >= n
        return finalize_scan(found) if buf.getbyte(i) == RBRACE
        return nil unless buf.getbyte(i) == DQUOTE

        key_start = i
        i = scan_string(buf, i, n)
        return :incomplete unless i
        key = buf.byteslice(key_start + 1, i - key_start - 2)

        # First key that is not meta/summary ends the scan (old format or body)
        return finalize_scan(found) unless key == "meta" || key == "summary"

        i = skip_ws(buf, i, n)
        return :incomplete if i >= n
        return nil unless buf.getbyte(i) == COLON
        i += 1
        i = skip_ws(buf, i, n)
        return :incomplete if i >= n

        vstart = i
        i = scan_value(buf, i, n)
        return :incomplete unless i
        fragment = buf.byteslice(vstart, i - vstart).force_encoding(Encoding::UTF_8)
        found[key.to_sym] = JSON.parse(fragment, symbolize_names: true)
        return finalize_scan(found) if found.key?(:meta) && found.key?(:summary)

        i = skip_ws(buf, i, n)
        return :incomplete if i >= n
        case buf.getbyte(i)
        when COMMA then i += 1
        when RBRACE then return finalize_scan(found)
        else return nil
        end
      end
    rescue JSON::ParserError
      nil
    end

    def finalize_scan(found)
      found.empty? ? nil : { meta: found[:meta], summary: found[:summary] }
    end

    def skip_ws(buf, i, n)
      while i < n
        b = buf.getbyte(i)
        break unless b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d
        i += 1
      end
      i
    end

    # Scan a JSON string starting at the opening quote.
    # Returns the index just past the closing quote, or nil if truncated.
    def scan_string(buf, i, n)
      j = i + 1
      while j < n
        b = buf.getbyte(j)
        if b == BSLASH
          j += 2
        elsif b == DQUOTE
          return j + 1
        else
          j += 1
        end
      end
      nil
    end

    # Scan a JSON value (string, container, or scalar) starting at i.
    # Returns the index just past the value, or nil if truncated.
    def scan_value(buf, i, n)
      case buf.getbyte(i)
      when DQUOTE
        scan_string(buf, i, n)
      when LBRACE, LBRACKET
        depth = 0
        j = i
        while j < n
          b = buf.getbyte(j)
          if b == DQUOTE
            j = scan_string(buf, j, n)
            return nil unless j
          elsif b == LBRACE || b == LBRACKET
            depth += 1
            j += 1
          elsif b == RBRACE || b == RBRACKET
            depth -= 1
            j += 1
            return j if depth == 0
          else
            j += 1
          end
        end
        nil
      else
        # scalar: number, true, false, null
        j = i
        while j < n
          b = buf.getbyte(j)
          break if b == COMMA || b == RBRACE || b == RBRACKET ||
                   b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d
          j += 1
        end
        j < n ? j : nil
      end
    end
  end
end
