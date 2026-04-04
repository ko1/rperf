require_relative "rperf/version"
require "zlib"
require "stringio"

begin
  # gem install
  require "rperf.so"
rescue LoadError
  # local development
  require 'rbconfig'
  require_relative "../tmp/#{RbConfig::CONFIG['arch']}/rperf/#{RbConfig::CONFIG['RUBY_PROGRAM_VERSION']}/rperf.so"
end

module Rperf

  # --- Module-level state (single global profiler) ---
  # Profiling session
  @verbose = false               # verbose stats output on stop
  @output = nil                  # output file path (nil = no file)
  @format = nil                  # output format (:json, :pprof, :collapsed, :text, nil = auto)
  @stat = false                  # print user/sys/real summary to stderr
  @stat_start_mono = nil         # Process::CLOCK_MONOTONIC at start (for real time)
  @stat_start_times = nil        # Process.times at start (for user/sys time)
  @label_set_table = nil         # Array: label_set_id → frozen Hash
  @label_set_index = nil         # Hash: frozen label Hash → label_set_id
  # Multi-process (fork/spawn) support
  @_session_dir_output = false   # true when @output points to session dir (child process)
  @_session_dir_created = false  # true after first fork activates session dir
  @_fork_hook_installed = false  # true after Process._fork hook is prepended
  @_saved_env = nil              # saved ENV values for restore on stop (inherit: true)

  # Starts profiling.
  # format: :json, :pprof, :collapsed, or :text. nil = auto-detect from output extension
  #   .json.gz   → json (rperf native, default)
  #   .collapsed → collapsed stacks (FlameGraph / speedscope compatible)
  #   .txt       → text report (human/AI readable flat + cumulative table)
  #   .pb.gz     → pprof protobuf (gzip compressed)
  # inherit: controls child process profiling.
  #   :fork  — (default) automatically profile forked child processes via Process._fork hook.
  #            Session dir is created eagerly at start time. Spawned processes are NOT tracked.
  #   true   — profile both forked and spawned Ruby child processes. Sets RUBYOPT=-rrperf
  #            and RPERF_* env vars so spawned Ruby processes auto-start profiling.
  #            Use with caution: affects ALL spawned Ruby processes, including independent
  #            programs that may use rperf themselves.
  #   false  — do not track child processes (single-process mode).
  def self.start(frequency: 1000, mode: :cpu, output: nil, verbose: false, format: nil, stat: false, signal: nil, aggregate: true, defer: false, inherit: :fork)
    raise ArgumentError, "frequency must be a positive integer (got #{frequency.inspect})" unless frequency.is_a?(Integer) && frequency > 0
    raise ArgumentError, "frequency must be <= 10000 (10KHz), got #{frequency}" if frequency > 10_000
    raise ArgumentError, "mode must be :cpu or :wall, got #{mode.inspect}" unless %i[cpu wall].include?(mode)
    raise ArgumentError, "inherit must be :fork, true, or false, got #{inherit.inspect}" unless [true, false, :fork].include?(inherit)
    c_mode = mode == :cpu ? 0 : 1
    unless signal.nil? || signal == false || signal.is_a?(Integer)
      raise ArgumentError, "signal must be nil, false, or an Integer, got #{signal.inspect}"
    end
    c_signal = signal.nil? ? -1 : (signal ? signal.to_i : 0)
    if c_signal > 0
      raise ArgumentError, "signal mode is only supported on Linux" unless RUBY_PLATFORM =~ /linux/
      uncatchable = [Signal.list["KILL"], Signal.list["STOP"]].compact
      if uncatchable.include?(c_signal)
        name = Signal.signame(c_signal) rescue c_signal.to_s
        raise ArgumentError, "signal #{c_signal} (#{name}) cannot be caught; use a different signal"
      end
    end
    @verbose = verbose || ENV["RPERF_VERBOSE"] == "1"
    @output = output
    @format = format
    @stat = stat
    @stat_start_mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @stat_start_times = Process.times
    @label_set_table = nil
    @label_set_index = nil
    _c_start(frequency, c_mode, aggregate, c_signal, defer)

    # Set up child process tracking
    if inherit && !ENV["RPERF_SESSION_DIR"]
      _setup_inherit(mode, frequency, signal, aggregate, output, format, stat, inherit, defer)
    end

    if block_given?
      begin
        yield
      ensure
        result = stop
      end
      result
    end
  end

  # VM state integer → label value mapping.
  # These values appear in the "Ruby" label key.
  VM_STATE_LABELS = {
    1 => ["%GVL", "blocked"],
    2 => ["%GVL", "wait"],
    3 => ["%GC",  "mark"],
    4 => ["%GC",  "sweep"],
  }.freeze

  def self.stop
    # Check if we need to aggregate child process data.
    # @_session_dir_created: fork happened and session dir is active.
    # Otherwise: check for actual child profile files (spawn-only case).
    session_dir = ENV["RPERF_SESSION_DIR"]
    is_root = session_dir && Process.pid.to_s == ENV["RPERF_ROOT_PROCESS"]
    has_child_profiles = is_root && !@_session_dir_created &&
                         File.directory?(session_dir.to_s) &&
                         !Dir.glob(File.join(session_dir.to_s, "profile-*.json.gz")).empty?
    needs_aggregation = is_root && (@_session_dir_created || has_child_profiles)

    data = _c_stop
    return unless data

    # Record process times for multi-process aggregation
    times = Process.times
    start_times = @stat_start_times || Struct.new(:utime, :stime).new(0.0, 0.0)
    data[:user_ns] = ((times.utime - start_times.utime) * 1_000_000_000).to_i
    data[:sys_ns] = ((times.stime - start_times.stime) * 1_000_000_000).to_i

    # When aggregate: false, C extension returns :raw_samples but not
    # :aggregated_samples.  Build aggregated view so encoders always work.
    if data[:raw_samples] && !data[:aggregated_samples]
      merged = {}
      data[:raw_samples].each do |frames, weight, thread_seq, label_set_id, vm_state|
        key = [frames, thread_seq || 0, label_set_id || 0, vm_state || 0]
        if merged.key?(key)
          merged[key] += weight
        else
          merged[key] = weight
        end
      end
      data[:aggregated_samples] = merged.map { |(frames, ts, lsi, vs), w| [frames, w, ts, lsi, vs] }
    end

    merge_vm_state_labels!(data)

    if needs_aggregation
      # Root process with children: write root's own profile to session dir
      # (fixed json.gz format), then aggregate all profiles.
      # Root's @output/@format/@stat are preserved for the merged result.
      print_stats(data) if @verbose
      begin
        save(File.join(session_dir, "profile-#{Process.pid}.json.gz"), data, format: :json)
      rescue SystemCallError
        # Session dir may have been removed (e.g., test scenario) — continue to aggregation
      end
      merged = _aggregate_and_report
      if merged.nil? && data
        # Aggregation failed — fall back to root's own data
        $stderr.puts "rperf: warning: multi-process aggregation failed; writing root process data only"
        write_data(@output, data, @format) if @output
        print_stat(data) if @stat
      end
      _cleanup_session_state
      return merged || data
    end

    print_stats(data) if @verbose
    print_stat(data) if @stat

    if @output
      if @_session_dir_output
        # Child process writing to session dir — tolerate missing dir
        begin
          write_data(@output, data, @format)
        rescue SystemCallError
          # Parent may have already cleaned up the session dir (e.g., parent
          # exited first and rm_rf'd it), or disk is full. Silently skip —
          # crashing in at_exit is worse than losing one child's profile.
        end
      else
        write_data(@output, data, @format)
      end
      @output = nil
      @format = nil
    end

    _cleanup_session_state
    data
  end

  def self._cleanup_session_state
    session_dir = ENV.delete("RPERF_SESSION_DIR")
    ENV.delete("RPERF_ROOT_PROCESS")
    ENV.delete("RPERF_DEFER")
    @_session_dir_created = false
    @_session_dir_output = false
    # Restore ENV variables saved by _setup_inherit (inherit: true)
    if @_saved_env
      @_saved_env.each do |key, original|
        if original.nil?
          ENV.delete(key)
        else
          ENV[key] = original
        end
      end
      @_saved_env = nil
    end
    # Remove eagerly-created session dir if it's empty (no children ran)
    if session_dir && File.directory?(session_dir)
      begin
        Dir.rmdir(session_dir)  # only succeeds if empty
      rescue SystemCallError
        # not empty or already removed — fine
      end
    end
  end
  private_class_method :_cleanup_session_state

  # Returns a snapshot of the current profiling data without stopping.
  # Only works in aggregate mode (the default). Returns nil if not profiling.
  # The returned data has the same format as stop's return value and can be
  # passed to save(), PProf.encode(), Collapsed.encode(), or Text.encode().
  #
  # +clear:+ if true, resets aggregated data after taking the snapshot.
  # This allows interval-based profiling where each snapshot covers only
  # the period since the last clear.
  def self.snapshot(clear: false)
    data = _c_snapshot(clear)
    return unless data
    merge_vm_state_labels!(data)
    data
  end

  # Label set management for per-context profiling.
  # Label sets are stored as an Array of Hashes, indexed by label_set_id.
  # Index 0 is reserved (no labels).

  @label_set_table = nil  # Array of frozen Hash
  @label_set_index = nil  # Hash → id (for dedup)

  def self._init_label_sets
    @label_set_table = [{}]  # id 0 = no labels
    @label_set_index = { {} => 0 }
  end

  def self._intern_label_set(hash)
    hash.freeze
    @label_set_index[hash] ||= begin
      id = @label_set_table.size
      @label_set_table << hash
      _c_set_label_sets(@label_set_table)
      id
    end
  end

  # Merges the given keyword labels into the current thread's label set,
  # sets the result on the current thread, and returns [previous_id, new_id].
  # Callers use previous_id to restore labels after a block.
  def self._merge_and_set_label(kw)
    _init_label_sets unless @label_set_table

    cur_id = _c_get_label
    cur_labels = @label_set_table[cur_id] || {}
    kw.each_value { |v| v.freeze }
    new_labels = cur_labels.merge(kw).reject { |_, v| v.nil? }
    new_id = _intern_label_set(new_labels)
    _c_set_label(new_id)

    [cur_id, new_id]
  end
  private_class_method :_merge_and_set_label

  # Sets labels on the current thread for profiling annotation.
  # With a block: restores previous labels when the block exits.
  # Without a block: sets labels persistently on the current thread.
  # Labels are key-value pairs written into pprof sample labels.
  #
  #   Rperf.label(request: "abc") { handle_request }
  #   Rperf.label(request: "abc")  # persistent set
  #
  # Values of nil remove that key. Existing labels are merged.
  def self.label(**kw, &block)
    return yield if block && !_c_running?
    return unless _c_running?

    cur_id, _new_id = _merge_and_set_label(kw)

    if block
      begin
        yield
      ensure
        _c_set_label(cur_id)
      end
    end
  end

  # Profiles the given block: activates timer sampling for the duration
  # and optionally applies labels. Use with start(defer: true) to profile
  # only specific sections of code.
  #
  #   Rperf.start(defer: true, mode: :wall)
  #   Rperf.profile(endpoint: "/users") { handle_request }
  #   data = Rperf.stop
  #
  # Nesting is supported: timer stays active until the outermost profile exits.
  # Requires a block. Raises if profiling is not started.
  def self.profile(**kw, &block)
    raise ArgumentError, "Rperf.profile requires a block" unless block
    raise RuntimeError, "Rperf is not started" unless _c_running?

    cur_id, _new_id = _merge_and_set_label(kw)

    _c_profile_inc

    begin
      yield
    ensure
      _c_profile_dec
      _c_set_label(cur_id)
    end
  end

  # Returns the current thread's labels as a Hash.
  # Returns an empty Hash if no labels are set or profiling is not running.
  def self.labels
    return {} unless @label_set_table
    cur_id = _c_get_label
    @label_set_table[cur_id] || {}
  end


  # Merge vm_state from C samples into label_sets as a "Ruby" label key.
  # Mutates data in place: updates label_set_id on each sample, strips vm_state,
  # and extends label_sets with new entries as needed.
  def self.merge_vm_state_labels!(data)
    samples_key = data[:aggregated_samples] ? :aggregated_samples : :raw_samples
    samples = data[samples_key]
    return unless samples

    orig_label_sets = data[:label_sets]
    label_sets = (orig_label_sets || [{}]).dup
    mapping = {}  # [original_label_set_id, vm_state] => new_label_set_id
    modified = false

    samples.each do |sample|
      vm_state = sample[4] || 0
      next if vm_state == 0
      next unless VM_STATE_LABELS.key?(vm_state)

      label_set_id = sample[3] || 0
      cache_key = [label_set_id, vm_state]
      new_id = mapping[cache_key]
      unless new_id
        base = label_sets[label_set_id] || {}
        key, value = VM_STATE_LABELS[vm_state]
        new_ls = base.merge(key.to_sym => value).freeze
        new_id = label_sets.size
        label_sets << new_ls
        mapping[cache_key] = new_id
      end
      sample[3] = new_id
      modified = true
    end

    # Strip vm_state (5th element) from all samples
    samples.each { |s| s.pop if s.size > 4 }

    # Only set label_sets if they were already present or we added vm_state labels
    data[:label_sets] = label_sets if orig_label_sets || modified
  end
  private_class_method :merge_vm_state_labels!

  # Saves profiling data to a file.
  # format: :json, :pprof, :collapsed, or :text. nil = auto-detect from path extension
  #   .json.gz   → json (rperf native, gzip compressed, default)
  #   .json      → json (plain text, readable by jq etc.)
  #   .collapsed → collapsed stacks (FlameGraph / speedscope compatible)
  #   .txt       → text report (human/AI readable flat + cumulative table)
  #   .pb.gz     → pprof protobuf (gzip compressed)
  def self.save(path, data, format: nil)
    write_data(path, data, format)
  end

  def self.write_data(path, data, format)
    fmt = detect_format(path, format)
    case fmt
    when :collapsed
      File.write(path, Collapsed.encode(data))
    when :text
      File.write(path, Text.encode(data))
    when :json
      require "json"
      json_data = data.merge(rperf_version: VERSION, pid: Process.pid, ppid: Process.ppid)
      json_str = JSON.generate(json_data)
      if path.to_s.end_with?(".gz")
        File.binwrite(path, gzip(json_str))
      else
        File.write(path, json_str)
      end
    else
      File.binwrite(path, gzip(PProf.encode(data)))
    end
  end
  private_class_method :write_data

  # Load a profile saved by rperf record (.json.gz or .json).
  # Returns the data hash (same format as Rperf.stop / Rperf.snapshot).
  # Warns to stderr if the file was saved by a different rperf version.
  def self.load(path)
    raw_bytes = File.binread(path)
    # Auto-detect gzip by magic bytes (1f 8b)
    raw = if raw_bytes.byteslice(0, 2) == "\x1f\x8b".b
      Zlib::GzipReader.new(StringIO.new(raw_bytes)).read
    else
      raw_bytes
    end
    require "json"
    data = JSON.parse(raw, symbolize_names: true)
    saved_version = data.delete(:rperf_version)
    if saved_version && saved_version != VERSION
      $stderr.puts "rperf: warning: file was saved by rperf #{saved_version} (current: #{VERSION})"
    elsif saved_version.nil?
      $stderr.puts "rperf: warning: file has no version info (may be from an older rperf)"
    end
    data
  end

  def self.detect_format(path, format)
    return format.to_sym if format
    case path.to_s
    when /\.collapsed\z/   then :collapsed
    when /\.txt\z/         then :text
    when /\.json(\.gz)?\z/ then :json
    else :pprof
    end
  end
  private_class_method :detect_format

  def self.gzip(data)
    io = StringIO.new
    io.set_encoding("ASCII-8BIT")
    gz = Zlib::GzipWriter.new(io)
    gz.write(data)
    gz.close
    io.string
  end

  def self.print_stats(data)
    count = data[:sampling_count] || 0
    total_ns = data[:sampling_time_ns] || 0
    mode = data[:mode] || :cpu
    frequency = data[:frequency] || 0

    total_ms = total_ns / 1_000_000.0
    avg_us = count > 0 ? total_ns / count / 1000.0 : 0.0

    $stderr.puts "[Rperf] mode=#{mode} frequency=#{frequency}Hz"
    $stderr.puts "[Rperf] sampling: #{count} calls, #{format("%.2f", total_ms)}ms total, #{format("%.1f", avg_us)}us/call avg"
    $stderr.puts "[Rperf] samples recorded: #{count}"

    print_top(data)
  end

  TOP_N = 10

  # Compute flat and cumulative weight tables from raw samples.
  # Returns { flat: Hash, cum: Hash, total_weight: Integer }
  def self.compute_flat_cum(samples_raw)
    flat = Hash.new(0)
    cum = Hash.new(0)
    total_weight = 0

    samples_raw.each do |frames, weight|
      total_weight += weight
      seen = {}

      frames.each_with_index do |frame, i|
        path, label = frame
        key = [label, path]

        flat[key] += weight if i == 0  # leaf = first element (deepest frame)

        unless seen[key]
          cum[key] += weight
          seen[key] = true
        end
      end
    end

    { flat: flat, cum: cum, total_weight: total_weight }
  end
  private_class_method :compute_flat_cum

  # Samples from C are now [[path_str, label_str], ...], weight]
  def self.print_top(data)
    samples_raw = data[:aggregated_samples]
    return if !samples_raw || samples_raw.empty?

    result = compute_flat_cum(samples_raw)
    return if result[:cum].empty?

    print_top_table("flat", result[:flat], result[:total_weight])
    print_top_table("cum", result[:cum], result[:total_weight])
  end

  def self.print_top_table(kind, table, total_weight)
    top = table.sort_by { |_, w| -w }.first(TOP_N)
    $stderr.puts "[Rperf] top #{top.size} by #{kind}:"
    top.each do |key, weight|
      label, path = key
      ms = weight / 1_000_000.0
      pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
      loc = path.empty? ? "" : " (#{path})"
      $stderr.puts format("[Rperf]   %8.1fms %5.1f%%  %s%s", ms, pct, label, loc)
    end
  end

  # Column formatters for stat output
  STAT_PCT_LINE  = ->(val, unit, pct, label) {
    format("  %14s %-2s %5.1f%%  %s", val, unit, pct, label)
  }
  STAT_LINE = ->(val, unit, label) {
    format("  %14s %-2s         %s", val, unit, label)
  }
  private_constant :STAT_PCT_LINE, :STAT_LINE

  def self.print_stat(data)
    samples_raw = data[:aggregated_samples] || []
    real_ns = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @stat_start_mono) * 1_000_000_000).to_i
    times = Process.times
    start_times = @stat_start_times || Struct.new(:utime, :stime).new(0.0, 0.0)
    user_ns = ((times.utime - start_times.utime) * 1_000_000_000).to_i
    sys_ns = ((times.stime - start_times.stime) * 1_000_000_000).to_i

    # In multi-process mode, use aggregated user/sys from all processes
    process_count = data[:process_count] || 0
    if process_count > 1 && data[:user_ns]
      user_ns = data[:user_ns]
      sys_ns = data[:sys_ns] || 0
    end

    command = ENV["RPERF_STAT_COMMAND"] || "(unknown)"

    $stderr.puts
    $stderr.puts " Performance stats for '#{command}':"
    $stderr.puts
    $stderr.puts format("  %14s ms   user", format_ms(user_ns))
    $stderr.puts format("  %14s ms   sys", format_ms(sys_ns))
    $stderr.puts format("  %14s ms   real", format_ms(real_ns))

    if samples_raw.size > 0
      breakdown, total_weight = compute_stat_breakdown(samples_raw, data[:label_sets])
      print_stat_breakdown(breakdown, total_weight, data)
      print_stat_runtime_info(data)
      print_stat_system_info(data)
      print_stat_report(data) if ENV["RPERF_STAT_REPORT"] == "1"
      print_stat_footer(samples_raw, real_ns, data)
    end

    $stderr.puts
  end

  def self.compute_stat_breakdown(samples_raw, label_sets)
    breakdown = Hash.new(0)
    total_weight = 0

    samples_raw.each do |frames, weight, _thread_seq, label_set_id|
      total_weight += weight
      category = :cpu_execution
      if label_sets && label_set_id && label_set_id > 0
        ls = label_sets[label_set_id]
        if ls
          gvl = ls[:"%GVL"]
          gc  = ls[:"%GC"]
          if gvl == "blocked"    then category = :gvl_blocked
          elsif gvl == "wait"    then category = :gvl_wait
          elsif gc  == "mark"    then category = :gc_marking
          elsif gc  == "sweep"   then category = :gc_sweeping
          end
        end
      end
      breakdown[category] += weight
    end

    [breakdown, total_weight]
  end
  private_class_method :compute_stat_breakdown

  def self.print_stat_breakdown(breakdown, total_weight, data)
    $stderr.puts
    process_count = data[:process_count] || 0
    if process_count > 1
      $stderr.puts STAT_LINE.call(format_integer(process_count), "  ", "[Rperf] Ruby processes profiled")
    end

    [
      [:cpu_execution, "[Rperf] CPU execution"],
      [:gvl_blocked,   "[Rperf] GVL blocked (I/O, sleep)"],
      [:gvl_wait,      "[Rperf] GVL wait (contention)"],
      [:gc_marking,    "[Rperf] GC marking"],
      [:gc_sweeping,   "[Rperf] GC sweeping"],
    ].each do |key, label|
      w = breakdown[key]
      next if w == 0
      pct = total_weight > 0 ? w * 100.0 / total_weight : 0.0
      $stderr.puts STAT_PCT_LINE.call(format_ms(w), "ms", pct, label)
    end
  end
  private_class_method :print_stat_breakdown

  def self.print_stat_runtime_info(data)
    gc = GC.stat
    $stderr.puts STAT_LINE.call(format_ms(gc[:time] * 1_000_000), "ms",
                                "[Ruby ] GC time (%s count: %s minor, %s major)" % [
                                  format_integer(gc[:count]),
                                  format_integer(gc[:minor_gc_count]),
                                  format_integer(gc[:major_gc_count])])
    $stderr.puts STAT_LINE.call(format_integer(gc[:total_allocated_objects]), "  ", "[Ruby ] allocated objects")
    $stderr.puts STAT_LINE.call(format_integer(gc[:total_freed_objects]), "  ", "[Ruby ] freed objects")
    thread_count = data[:detected_thread_count] || 0
    $stderr.puts STAT_LINE.call(format_integer(thread_count), "  ", "[Ruby ] detected threads") if thread_count > 0
    if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      yjit = RubyVM::YJIT.runtime_stats
      if yjit[:ratio_in_yjit]
        $stderr.puts STAT_LINE.call(format("%.1f%%", yjit[:ratio_in_yjit] * 100), "  ", "[Ruby ] YJIT code execution ratio")
      end
    end
  end
  private_class_method :print_stat_runtime_info

  def self.print_stat_system_info(data = nil)
    sys_stats = get_system_stats
    maxrss_kb = sys_stats[:maxrss_kb]
    if maxrss_kb
      $stderr.puts STAT_LINE.call(format_integer((maxrss_kb / 1024.0).round), "MB", "[OS   ] peak memory (maxrss)")
    end
    if sys_stats[:page_faults_minor]
      minor = sys_stats[:page_faults_minor]
      major = sys_stats[:page_faults_major]
      $stderr.puts STAT_LINE.call(
        format_integer(minor + major), "  ",
        "[OS   ] page faults (%s minor, %s major)" % [
          format_integer(minor), format_integer(major)])
    end
    if sys_stats[:ctx_voluntary]
      $stderr.puts STAT_LINE.call(
        format_integer(sys_stats[:ctx_voluntary] + sys_stats[:ctx_involuntary]), "  ",
        "[OS   ] context switches (%s voluntary, %s involuntary)" % [
          format_integer(sys_stats[:ctx_voluntary]),
          format_integer(sys_stats[:ctx_involuntary])])
    end
    if sys_stats[:io_read_bytes]
      r = sys_stats[:io_read_bytes]
      w = sys_stats[:io_write_bytes]
      $stderr.puts STAT_LINE.call(
        format_integer(((r + w) / 1024.0 / 1024.0).round), "MB",
        "[OS   ] disk I/O (%s MB read, %s MB write)" % [
          format_integer((r / 1024.0 / 1024.0).round),
          format_integer((w / 1024.0 / 1024.0).round)])
    end
    process_count = data[:process_count] if data
    if process_count && process_count > 1
      $stderr.puts STAT_LINE.call("", "  ", "(GC/OS stats are from root process only; user/sys/[Rperf] lines are aggregated)")
    end
  end
  private_class_method :print_stat_system_info


  def self.print_stat_report(data)
    $stderr.puts
    $stderr.puts Text.encode(data, header: false)
  end
  private_class_method :print_stat_report

  def self.print_stat_footer(samples_raw, real_ns, data)
    triggers = data[:trigger_count] || 0
    sampling_time_ns = data[:sampling_time_ns] || 0
    # In multi-process mode, use sum of all processes' durations as denominator.
    # Single-process: fall back to root's real_ns.
    total_real_ns = data[:total_duration_ns] || real_ns
    total_real_ns = real_ns if total_real_ns == 0
    overhead_pct = total_real_ns > 0 ? sampling_time_ns * 100.0 / total_real_ns : 0.0
    $stderr.puts
    samples = data[:sampling_count] || samples_raw.size
    $stderr.puts format("  %d samples / %d triggers, %.1f%% profiler overhead",
                        samples, triggers, overhead_pct)
    dropped = data[:dropped_samples] || 0
    if dropped > 0
      $stderr.puts format("  WARNING: %d samples dropped due to memory allocation failure", dropped)
    end
    dropped_agg = data[:dropped_aggregation] || 0
    if dropped_agg > 0
      $stderr.puts format("  WARNING: %d samples dropped during aggregation (frame/stack table full)", dropped_agg)
    end
  end
  private_class_method :print_stat_footer

  def self.format_integer(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
  private_class_method :format_integer

  # Format nanoseconds as ms with 1 decimal place and comma-separated integer part.
  # Example: 5_609_200_000 → "5,609.2"
  def self.format_ms(ns)
    ms = ns / 1_000_000.0
    formatted = format("%.1f", ms)
    int_str, frac = formatted.split(".")
    int_str = int_str.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    "#{int_str}.#{frac}"
  end
  private_class_method :format_ms

  # Collect system-level stats. Returns a hash; missing keys are omitted.
  def self.get_system_stats
    stats = {}

    if File.readable?("/proc/self/status")
      # Linux: parse /proc/self/status
      File.read("/proc/self/status").each_line do |line|
        case line
        when /\AVmHWM:\s+(\d+)\s+kB/
          stats[:maxrss_kb] = $1.to_i
        when /\Avoluntary_ctxt_switches:\s+(\d+)/
          stats[:ctx_voluntary] = $1.to_i
        when /\Anonvoluntary_ctxt_switches:\s+(\d+)/
          stats[:ctx_involuntary] = $1.to_i
        end
      end
    else
      # macOS/BSD: ps reports RSS in KB
      rss = `ps -o rss= -p #{$$}`.strip.to_i rescue nil
      stats[:maxrss_kb] = rss if rss && rss > 0
    end

    if File.readable?("/proc/self/stat")
      fields = File.read("/proc/self/stat").split
      stats[:page_faults_minor] = fields[9].to_i
      stats[:page_faults_major] = fields[11].to_i
    end

    if File.readable?("/proc/self/io")
      # Linux: parse /proc/self/io
      File.read("/proc/self/io").each_line do |line|
        case line
        when /\Aread_bytes:\s+(\d+)/
          stats[:io_read_bytes] = $1.to_i
        when /\Awrite_bytes:\s+(\d+)/
          stats[:io_write_bytes] = $1.to_i
        end
      end
    end

    stats
  end
  private_class_method :get_system_stats

  # --- Multi-process (fork) support ---

  # Set up child process tracking from Rperf.start(inherit: ...).
  # Called only when NOT already inside a CLI-managed session (no RPERF_SESSION_DIR).
  # Creates the session directory eagerly — if creation fails, inherit is silently
  # disabled and profiling continues in single-process mode.
  def self._setup_inherit(mode, frequency, signal, aggregate, output, format, stat, inherit, defer)
    session_dir = _create_session_dir
    return unless session_dir

    ENV["RPERF_ROOT_PROCESS"] = Process.pid.to_s
    ENV["RPERF_SESSION_DIR"] = session_dir
    ENV["RPERF_DEFER"] = "1" if defer

    _install_fork_hook

    if inherit == true
      # inherit: true — also track spawned Ruby children via RUBYOPT.
      # Save original values so _cleanup_session_state can restore them.
      env_keys = %w[RPERF_ENABLED RPERF_FREQUENCY RPERF_MODE RPERF_SIGNAL RPERF_AGGREGATE RUBYLIB RUBYOPT]
      @_saved_env = env_keys.to_h { |k| [k, ENV[k]] }

      ENV["RPERF_ENABLED"] = "1"
      ENV["RPERF_FREQUENCY"] = frequency.to_s
      ENV["RPERF_MODE"] = mode.to_s
      ENV["RPERF_SIGNAL"] = signal.nil? ? nil : signal.to_s
      ENV["RPERF_AGGREGATE"] = aggregate ? nil : "0"
      lib_dir = File.expand_path("..", __FILE__)
      ENV["RUBYLIB"] = [lib_dir, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR)
      ENV["RUBYOPT"] = "-rrperf #{ENV['RUBYOPT']}".strip
    end
  end
  private_class_method :_setup_inherit

  # Create session directory eagerly.  Returns the session dir path on success,
  # nil on failure (caller should fall back to single-process mode).
  # Try each candidate base in order.  If user_dir looks usable but
  # session_dir creation fails (quota, ACL, sandbox, etc.), fall through
  # to the next base instead of giving up.
  # When clean_stale: true, removes session dirs from dead processes.
  def self._create_session_dir(clean_stale: false)
    require "securerandom"
    require "tmpdir"

    bases = [ENV["RPERF_TMPDIR"], ENV["XDG_RUNTIME_DIR"], Dir.tmpdir].compact
    bases.each do |base|
      user_dir = File.join(base, "rperf-#{Process.uid}")

      if File.directory?(user_dir)
        st = File.stat(user_dir) rescue next
        next unless st.owned? && (st.mode & 0777) == 0700
      elsif File.writable?(base)
        begin
          Dir.mkdir(user_dir, 0700)
        rescue Errno::EEXIST
          st = File.stat(user_dir) rescue next
          next unless st.owned? && (st.mode & 0777) == 0700
        rescue SystemCallError
          next
        end
      else
        next
      end

      if clean_stale
        require "fileutils"
        Dir.glob(File.join(user_dir, "rperf-*")).each do |dir|
          m = File.basename(dir).match(/\Arperf-(\d+)-/)
          next unless m
          pid = m[1].to_i
          begin
            Process.kill(0, pid)
          rescue Errno::ESRCH
            FileUtils.rm_rf(dir)
          rescue Errno::EPERM
            # not ours
          end
        end
      end

      session_dir = File.join(user_dir, "rperf-#{Process.pid}-#{SecureRandom.hex(4)}")
      begin
        Dir.mkdir(session_dir, 0700)
        return session_dir
      rescue SystemCallError
        next
      end
    end
    nil
  end
  private_class_method :_create_session_dir

  def self._parse_signal_env
    case ENV["RPERF_SIGNAL"]
    when nil then nil
    when "false" then false
    when /\A\d+\z/ then ENV["RPERF_SIGNAL"].to_i
    end
  end
  private_class_method :_parse_signal_env

  def self._install_fork_hook
    return if @_fork_hook_installed
    @_fork_hook_installed = true

    ::Process.singleton_class.prepend(Module.new {
      def _fork
        if !Rperf.instance_variable_get(:@_session_dir_created) &&
           Process.pid.to_s == ENV["RPERF_ROOT_PROCESS"]
          Rperf._on_first_fork
        end
        pid = super
        if pid == 0
          Rperf._restart_in_child
        end
        pid
      end
    })
  end
  private_class_method :_install_fork_hook

  def self._on_first_fork
    return if @_session_dir_created
    session_dir = ENV["RPERF_SESSION_DIR"]
    return unless session_dir && File.directory?(session_dir)

    @_session_dir_created = true
    # Root's @output/@format/@stat are kept as-is (user's original settings).
    # stop() writes root's profile to session dir with fixed json.gz format,
    # then uses the original settings for the merged output.
  end

  def self._restart_in_child
    session_dir = ENV["RPERF_SESSION_DIR"]
    return unless session_dir && File.directory?(session_dir)
    return if _c_running?  # should not happen, but guard against it

    # C state is already cleaned up by pthread_atfork child handler.
    @label_set_table = nil
    @label_set_index = nil

    child_output = File.join(session_dir, "profile-#{Process.pid}.json.gz")

    opts = {
      frequency: (ENV["RPERF_FREQUENCY"] || 1000).to_i,
      mode: ENV["RPERF_MODE"] == "cpu" ? :cpu : :wall,
      aggregate: ENV["RPERF_AGGREGATE"] != "0",
      output: child_output,
      format: :json,
      stat: false,
      verbose: false,
    }
    sig = _parse_signal_env
    opts[:signal] = sig unless sig.nil?
    opts[:defer] = true if ENV["RPERF_DEFER"] == "1"

    start(**opts, inherit: false)
    @_session_dir_output = true
    label("%pid": Process.pid.to_s)

    # Register at_exit so child's profile is written even without explicit stop
    at_exit { Rperf.stop }
  end

  def self._aggregate_and_report
    session_dir = ENV["RPERF_SESSION_DIR"]
    return unless session_dir && File.directory?(session_dir)

    merged_samples = []
    merged_label_sets = [{}]
    merged_label_sets_index = { {} => 0 }
    total_trigger_count = 0
    total_sampling_count = 0
    total_sampling_time_ns = 0
    max_duration_ns = 0
    total_duration_ns = 0
    total_user_ns = 0
    total_sys_ns = 0
    process_count = 0

    Dir.glob(File.join(session_dir, "profile-*.json.gz")).each do |file|
      begin
        data = load(file)
      rescue StandardError => e
        $stderr.puts "rperf: warning: failed to load #{file}: #{e.message}"
        next
      end
      next unless data
      _merge_into(merged_samples, merged_label_sets, data, merged_label_sets_index)
      total_trigger_count += (data[:trigger_count] || 0)
      total_sampling_count += (data[:sampling_count] || 0)
      total_sampling_time_ns += (data[:sampling_time_ns] || 0)
      d = data[:duration_ns] || 0
      max_duration_ns = d if d > max_duration_ns
      total_duration_ns += d
      total_user_ns += (data[:user_ns] || 0)
      total_sys_ns += (data[:sys_ns] || 0)
      process_count += 1
    end

    return if process_count == 0

    merged_data = {
      mode: (ENV["RPERF_MODE"] || "wall").to_sym,
      frequency: (ENV["RPERF_FREQUENCY"] || 1000).to_i,
      aggregated_samples: merged_samples,
      label_sets: merged_label_sets,
      trigger_count: total_trigger_count,
      sampling_count: total_sampling_count,
      sampling_time_ns: total_sampling_time_ns,
      duration_ns: max_duration_ns,
      total_duration_ns: total_duration_ns,
      user_ns: total_user_ns,
      sys_ns: total_sys_ns,
      process_count: process_count,
    }

    print_stat(merged_data) if @stat
    if @output
      write_data(@output, merged_data, @format)
    end

    _cleanup_session_dir(session_dir)

    merged_data
  rescue => e
    $stderr.puts "rperf: warning: failed to aggregate multi-process data: #{e.message}"
    # Fallback: try to write whatever individual profiles exist as-is
    _fallback_aggregate_output(session_dir)
    _cleanup_session_dir(session_dir)
    nil
  end
  # Not private — called from at_exit block which runs in top-level context

  def self._cleanup_session_dir(session_dir)
    require "fileutils"
    FileUtils.rm_rf(session_dir)
  rescue => e
    $stderr.puts "rperf: warning: failed to clean up session dir: #{e.message}"
  end
  private_class_method :_cleanup_session_dir

  # Best-effort fallback: if aggregation failed, try to copy the first
  # available child profile to @output so the user gets something.
  def self._fallback_aggregate_output(session_dir)
    return unless @output
    return unless session_dir && File.directory?(session_dir)
    files = Dir.glob(File.join(session_dir, "profile-*.json.gz"))
    return if files.empty?
    require "fileutils"
    FileUtils.cp(files.first, @output)
  rescue StandardError
    # nothing more we can do
  end
  private_class_method :_fallback_aggregate_output

  def self._merge_into(merged_samples, merged_label_sets, data, merged_label_sets_index = nil)
    # Build a reverse index on first call for O(1) dedup lookups
    unless merged_label_sets_index
      merged_label_sets_index = {}
      merged_label_sets.each_with_index { |ls, i| merged_label_sets_index[ls] = i }
    end

    child_label_sets = data[:label_sets] || [{}]
    id_map = {}
    child_label_sets.each_with_index do |ls, child_id|
      # Normalize keys to symbols for consistent comparison
      normalized = ls.is_a?(Hash) ? ls.transform_keys(&:to_sym) : ls
      existing = merged_label_sets_index[normalized]
      if existing
        id_map[child_id] = existing
      else
        new_idx = merged_label_sets.size
        id_map[child_id] = new_idx
        merged_label_sets << normalized
        merged_label_sets_index[normalized] = new_idx
      end
    end

    (data[:aggregated_samples] || []).each do |frames, weight, thread_seq, label_set_id|
      new_lsi = id_map[label_set_id || 0] || 0
      merged_samples << [frames, weight, thread_seq, new_lsi]
    end
  end
  private_class_method :_merge_into

  # ENV-based auto-start for CLI usage
  if ENV["RPERF_ENABLED"] == "1"
    _rperf_mode_str = ENV["RPERF_MODE"] || "cpu"
    unless %w[cpu wall].include?(_rperf_mode_str)
      raise ArgumentError, "RPERF_MODE must be 'cpu' or 'wall', got: #{_rperf_mode_str.inspect}"
    end
    _rperf_mode = _rperf_mode_str == "wall" ? :wall : :cpu
    _rperf_format = if ENV["RPERF_FORMAT"]
                      unless %w[pprof collapsed text json].include?(ENV["RPERF_FORMAT"])
                        raise ArgumentError, "RPERF_FORMAT must be one of pprof, collapsed, text, json, got: #{ENV["RPERF_FORMAT"].inspect}"
                      end
                      ENV["RPERF_FORMAT"].to_sym
                    end
    _rperf_stat = ENV["RPERF_STAT"] == "1"
    _rperf_signal = _parse_signal_env
    _rperf_aggregate = ENV["RPERF_AGGREGATE"] != "0"
    _rperf_original_output = _rperf_stat ? ENV["RPERF_OUTPUT"] : (ENV["RPERF_OUTPUT"] || "rperf.json.gz")

    _rperf_start_opts = { frequency: (ENV["RPERF_FREQUENCY"] || 1000).to_i, mode: _rperf_mode,
                          verbose: ENV["RPERF_VERBOSE"] == "1",
                          aggregate: _rperf_aggregate }
    _rperf_start_opts[:signal] = _rperf_signal unless _rperf_signal.nil?
    _rperf_start_opts[:defer] = true if ENV["RPERF_DEFER"] == "1"

    if ENV["RPERF_SESSION_DIR"] && Process.pid.to_s != ENV["RPERF_ROOT_PROCESS"]
      # spawn / fork+exec child: write to session dir, no aggregation.
      # Session dir is created eagerly by the root process (CLI or API).
      # If it doesn't exist, skip profiling entirely — don't fall back to
      # normal mode which would duplicate output with the root process.
      _rperf_session_dir = ENV["RPERF_SESSION_DIR"]
      if File.directory?(_rperf_session_dir)
        _rperf_start_opts[:output] = File.join(_rperf_session_dir, "profile-#{Process.pid}.json.gz")
        _rperf_start_opts[:format] = :json
        _rperf_start_opts[:stat] = false
        _rperf_start_opts[:verbose] = false

        _install_fork_hook
        start(**_rperf_start_opts, inherit: false)
        @_session_dir_output = true
        label("%pid": Process.pid.to_s)
        at_exit { stop }
      end
    elsif ENV["RPERF_SESSION_DIR"]
      # Root process: start with normal output settings.
      # If no fork/spawn happens, behaves exactly like single-process mode.
      _rperf_start_opts[:output] = _rperf_original_output
      _rperf_start_opts[:format] = _rperf_format
      _rperf_start_opts[:stat] = _rperf_stat

      _install_fork_hook
      start(**_rperf_start_opts, inherit: false)

      at_exit { Rperf.stop }
    else
      _rperf_start_opts[:output] = _rperf_original_output
      _rperf_start_opts[:format] = _rperf_format
      _rperf_start_opts[:stat] = _rperf_stat
      _rperf_start_opts[:inherit] = false  # no RPERF_SESSION_DIR means --no-inherit
      start(**_rperf_start_opts)
      at_exit { stop }
    end
  end

  # Text report encoder — human/AI readable flat + cumulative top-N table.
  module Text
    module_function

    def encode(data, top_n: 50, header: true)
      samples_raw = data[:aggregated_samples]
      mode = data[:mode] || :cpu
      frequency = data[:frequency] || 0

      return "No samples recorded.\n" if !samples_raw || samples_raw.empty?

      result = Rperf.send(:compute_flat_cum, samples_raw)

      out = String.new
      if header
        total_ms = result[:total_weight] / 1_000_000.0
        out << "Total: #{"%.1f" % total_ms}ms (#{mode})\n"
        sample_count = data[:sampling_count] || samples_raw.size
        out << "Samples: #{sample_count}, Frequency: #{frequency}Hz\n"
        out << "\n"
      end
      out << format_table("Flat", result[:flat], result[:total_weight], top_n)
      out << "\n"
      out << format_table("Cumulative", result[:cum], result[:total_weight], top_n)
      out
    end

    def format_table(title, table, total_weight, top_n)
      sorted = table.sort_by { |_, w| -w }.first(top_n)
      out = String.new
      out << " #{title}:\n"
      sorted.each do |key, weight|
        label, path = key
        pct = total_weight > 0 ? weight * 100.0 / total_weight : 0.0
        loc = path.empty? ? "" : " (#{path})"
        out << format("  %14s ms %5.1f%%  %s%s\n", Rperf.send(:format_ms, weight), pct, label, loc)
      end
      out
    end
  end

  # Collapsed stacks encoder for FlameGraph / speedscope.
  # Output: one line per unique stack, "frame1;frame2;...;leafN weight\n"
  module Collapsed
    module_function

    def encode(data)
      samples = data[:aggregated_samples]
      return "" if !samples || samples.empty?
      merged = Hash.new(0)
      samples.each do |frames, weight|
        key = frames.reverse.map { |_, label| label }.join(";")
        merged[key] += weight
      end
      merged.map { |stack, weight| "#{stack} #{weight}" }.join("\n") + "\n"
    end
  end

  # Hand-written protobuf encoder for pprof profile format.
  # Only runs once at stop time, so performance is not critical.
  #
  # Samples from C are: [[[path_str, label_str], ...], weight]
  # This encoder builds its own string table for pprof output.
  module PProf
    module_function

    def encode(data)
      samples_raw = data[:aggregated_samples]
      frequency = data[:frequency]
      interval_ns = 1_000_000_000 / frequency
      mode = data[:mode] || :cpu

      # Build string table: index 0 must be ""
      string_table = [""]
      string_index = { "" => 0 }

      intern = ->(s) {
        string_index[s] ||= begin
          idx = string_table.size
          string_table << s
          idx
        end
      }

      # Convert string frames to index frames and merge identical stacks per thread/label
      merged = Hash.new(0)
      thread_seq_key = intern.("thread_seq")
      label_sets = data[:label_sets]  # Array of Hash (may be nil)
      samples_raw.each do |frames, weight, thread_seq, label_set_id|
        key = [frames.map { |path, label| [intern.(path), intern.(label)] }, thread_seq || 0, label_set_id || 0]
        merged[key] += weight
      end
      merged = merged.to_a

      # Intern label set keys/values for pprof labels
      label_key_indices = {}  # String key → string_table index
      if label_sets
        label_sets.each do |ls|
          ls.each do |k, v|
            sk = k.to_s
            label_key_indices[sk] ||= intern.(sk)
            intern.(v.to_s)  # ensure value is interned
          end
        end
      end

      # Build location/function tables
      locations, functions = build_tables(merged.map { |(frames, _, _), w| [frames, w] })

      # Intern type label and unit
      type_label = mode == :wall ? "wall" : "cpu"
      type_idx = intern.(type_label)
      ns_idx = intern.("nanoseconds")

      # Encode Profile message
      buf = "".b

      # field 1: sample_type (repeated ValueType)
      buf << encode_message(1, encode_value_type(type_idx, ns_idx))

      # field 2: sample (repeated Sample) with thread_seq + user labels
      merged.each do |(frames, thread_seq, label_set_id), weight|
        sample_buf = "".b
        loc_ids = frames.map { |f| locations[f] }
        sample_buf << encode_packed_uint64(1, loc_ids)
        sample_buf << encode_packed_int64(2, [weight])
        if thread_seq && thread_seq > 0
          label_buf = "".b
          label_buf << encode_int64(1, thread_seq_key)  # key
          label_buf << encode_int64(3, thread_seq)       # num
          sample_buf << encode_message(3, label_buf)
        end
        if label_sets && label_set_id && label_set_id > 0
          ls = label_sets[label_set_id]
          if ls
            ls.each do |k, v|
              label_buf = "".b
              label_buf << encode_int64(1, label_key_indices[k.to_s])  # key
              label_buf << encode_int64(2, string_index[v.to_s])       # str
              sample_buf << encode_message(3, label_buf)
            end
          end
        end
        buf << encode_message(2, sample_buf)
      end

      # field 4: location (repeated Location)
      locations.each do |frame, loc_id|
        loc_buf = "".b
        loc_buf << encode_uint64(1, loc_id)
        line_buf = "".b
        func_id = functions[frame]
        line_buf << encode_uint64(1, func_id)
        loc_buf << encode_message(4, line_buf)
        buf << encode_message(4, loc_buf)
      end

      # field 5: function (repeated Function)
      functions.each do |frame, func_id|
        func_buf = "".b
        func_buf << encode_uint64(1, func_id)
        func_buf << encode_int64(2, frame[1])    # name (label_idx)
        func_buf << encode_int64(4, frame[0])    # filename (path_idx)
        buf << encode_message(5, func_buf)
      end

      # Intern comment and doc_url strings before encoding string_table
      comment_indices = [
        intern.("rperf #{Rperf::VERSION}"),
        intern.("mode: #{mode}"),
        intern.("frequency: #{frequency}Hz"),
        intern.("ruby: #{RUBY_DESCRIPTION}"),
      ]
      doc_url_idx = intern.("https://ko1.github.io/rperf/docs/help.html")

      # field 6: string_table (repeated string)
      string_table.each do |s|
        buf << encode_bytes(6, s.encode("UTF-8", invalid: :replace, undef: :replace))
      end

      # field 9: time_nanos (int64)
      if data[:start_time_ns]
        buf << encode_int64(9, data[:start_time_ns])
      end

      # field 10: duration_nanos (int64)
      if data[:duration_ns]
        buf << encode_int64(10, data[:duration_ns])
      end

      # field 11: period_type (ValueType)
      buf << encode_message(11, encode_value_type(type_idx, ns_idx))

      # field 12: period (int64)
      buf << encode_int64(12, interval_ns)

      # field 13: comment (repeated int64 = string_table index)
      comment_indices.each { |idx| buf << encode_int64(13, idx) }

      # field 15: doc_url (int64 = string_table index)
      buf << encode_int64(15, doc_url_idx)

      buf
    end

    def build_tables(merged)
      locations = {}
      functions = {}
      next_id = 1

      merged.each do |frames, _weight|
        frames.each do |frame|
          unless locations.key?(frame)
            locations[frame] = next_id
            functions[frame] = next_id
            next_id += 1
          end
        end
      end

      [locations, functions]
    end

    # --- Protobuf encoding helpers ---

    def encode_varint(value)
      value = value & 0xFFFFFFFF_FFFFFFFF if value < 0
      buf = "".b
      loop do
        byte = value & 0x7F
        value >>= 7
        if value > 0
          buf << (byte | 0x80).chr
        else
          buf << byte.chr
          break
        end
      end
      buf
    end

    def encode_uint64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value)
    end

    def encode_int64(field, value)
      encode_varint((field << 3) | 0) + encode_varint(value < 0 ? value + (1 << 64) : value)
    end

    def encode_bytes(field, data)
      data = data.b if data.respond_to?(:b)
      encode_varint((field << 3) | 2) + encode_varint(data.bytesize) + data
    end

    def encode_message(field, data)
      encode_bytes(field, data)
    end

    def encode_value_type(type_idx, unit_idx)
      encode_int64(1, type_idx) + encode_int64(2, unit_idx)
    end

    def encode_packed_uint64(field, values)
      inner = values.map { |v| encode_varint(v) }.join
      encode_bytes(field, inner)
    end

    def encode_packed_int64(field, values)
      inner = values.map { |v| encode_varint(v < 0 ? v + (1 << 64) : v) }.join
      encode_bytes(field, inner)
    end
  end
end
