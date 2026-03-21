# sperf - safepoint-based sampling performance profiler for Ruby

## OVERVIEW

sperf profiles Ruby programs by sampling at safepoints and using actual
time deltas (nanoseconds) as weights to correct safepoint bias.
POSIX systems (Linux, macOS). Requires Ruby >= 3.4.0.

## CLI USAGE

    sperf record [options] command [args...]
    sperf stat [options] command [args...]
    sperf report [options] [file]
    sperf help

### record: Profile and save to file.

    -o, --output PATH       Output file (default: sperf.data)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: cpu)
    --format FORMAT         pprof, collapsed, or text (default: auto from extension)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    -v, --verbose           Print sampling statistics to stderr

### stat: Run command and print performance summary to stderr.

Always uses wall mode. No file output by default.

    -o, --output PATH       Also save profile to file (default: none)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    -v, --verbose           Print additional sampling statistics

Shows: user/sys/real time, time breakdown (CPU execution, GVL blocked,
GVL wait, GC marking, GC sweeping), and top 5 hot functions.

### report: Open pprof profile with go tool pprof. Requires Go.

    --top                   Print top functions by flat time
    --text                  Print text report

Default (no flag): opens interactive web UI in browser.
Default file: sperf.data

### diff: Compare two pprof profiles (target - base). Requires Go.

    --top                   Print top functions by diff
    --text                  Print text diff report

Default (no flag): opens diff in browser.

### Examples

    sperf record ruby app.rb
    sperf record -o profile.pb.gz ruby app.rb
    sperf record -m wall -f 500 -o profile.pb.gz ruby server.rb
    sperf record -o profile.collapsed ruby app.rb
    sperf record -o profile.txt ruby app.rb
    sperf stat ruby app.rb
    sperf stat -o profile.pb.gz ruby app.rb
    sperf report
    sperf report --top profile.pb.gz
    sperf diff before.pb.gz after.pb.gz
    sperf diff --top before.pb.gz after.pb.gz

## RUBY API

```ruby
require "sperf"

# Block form (recommended) — profiles the block and writes to file
Sperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop — returns data hash for programmatic use
Sperf.start(frequency: 1000, mode: :wall)
# ... code to profile ...
data = Sperf.stop

# Save data to file later
Sperf.save("profile.pb.gz", data)
Sperf.save("profile.collapsed", data)
Sperf.save("profile.txt", data)
```

### Sperf.start parameters

    frequency:  Sampling frequency in Hz (Integer, default: 1000)
    mode:       :cpu or :wall (Symbol, default: :cpu)
    output:     File path to write on stop (String or nil)
    verbose:    Print statistics to stderr (true/false, default: false)
    format:     :pprof, :collapsed, :text, or nil for auto-detect (Symbol or nil)

### Sperf.stop return value

nil if profiler was not running; otherwise a Hash:

```ruby
{ mode: :cpu,             # or :wall
  frequency: 500,
  sampling_count: 1234,
  sampling_time_ns: 56789,
  start_time_ns: 17740..., # CLOCK_REALTIME epoch nanos
  duration_ns: 10000000,   # profiling duration in nanos
  samples: [               # Array of [frames, weight, thread_seq]
    [frames, weight, seq], #   frames: [[path, label], ...] deepest-first
    ...                    #   weight: Integer (nanoseconds)
  ] }                      #   seq: Integer (thread sequence, 1-based)
```

### Sperf.save(path, data, format: nil)

Writes data to path. format: :pprof, :collapsed, or :text.
nil auto-detects from extension.

## PROFILING MODES

- **cpu** — Measures per-thread CPU time via Linux thread clock.
  Use for: finding functions that consume CPU cycles.
  Ignores time spent sleeping, in I/O, or waiting for GVL.

- **wall** — Measures wall-clock time (CLOCK_MONOTONIC).
  Use for: finding where wall time goes, including I/O, sleep, GVL
  contention, and off-CPU waits.
  Includes synthetic frames (see below).

## OUTPUT FORMATS

### pprof (default)

Gzip-compressed protobuf. Standard pprof format.
Extension convention: `.pb.gz`
View with: `go tool pprof`, pprof-rs, or speedscope (via import).

Embedded metadata:

    comment         sperf version, mode, frequency, Ruby version
    time_nanos      profile collection start time (epoch nanoseconds)
    duration_nanos  profile duration (nanoseconds)
    doc_url         link to this documentation

Sample labels:

    thread_seq      thread sequence number (1-based, assigned per profiling session)

View comments: `go tool pprof -comments profile.pb.gz`

Group by thread: `go tool pprof -tagroot=thread_seq profile.pb.gz`

### collapsed

Plain text. One line per unique stack: `frame1;frame2;...;leaf weight`
Frames are semicolon-separated, bottom-to-top. Weight in nanoseconds.
Extension convention: `.collapsed`
Compatible with: FlameGraph (flamegraph.pl), speedscope.

### text

Human/AI-readable report. Shows total time, then flat and cumulative
top-N tables sorted by weight descending. No parsing needed.
Extension convention: `.txt`

Example output:

    Total: 1523.4ms (cpu)
    Samples: 4820, Frequency: 500Hz

    Flat:
         820.3ms  53.8%  Array#each (app/models/user.rb)
         312.1ms  20.5%  JSON.parse (lib/json/parser.rb)
         ...

    Cumulative:
        1401.2ms  92.0%  UsersController#index (app/controllers/users_controller.rb)
         ...

### Format auto-detection

Format is auto-detected from the output file extension:

    .collapsed → collapsed
    .txt       → text
    anything else → pprof

The `--format` flag (CLI) or `format:` parameter (API) overrides auto-detect.

## SYNTHETIC FRAMES

In wall mode, sperf adds synthetic frames that represent non-CPU time:

- **[GVL blocked]** — Time the thread spent off-GVL (I/O, sleep, C extension
  releasing GVL). Attributed to the stack at SUSPENDED.
- **[GVL wait]** — Time the thread spent waiting to reacquire the GVL after
  becoming ready. Indicates GVL contention. Same stack.

In both modes, GC time is tracked:

- **[GC marking]** — Time spent in GC marking phase (wall time).
- **[GC sweeping]** — Time spent in GC sweeping phase (wall time).

These always appear as the leaf (deepest) frame in a sample.

## INTERPRETING RESULTS

Weight unit is always nanoseconds regardless of mode.

- **Flat time**: weight attributed directly to a function (it was the leaf).
- **Cumulative time**: weight for all samples where the function appears
  anywhere in the stack.

High flat time → the function itself is expensive.
High cum but low flat → the function calls expensive children.

To convert: 1,000,000 ns = 1 ms, 1,000,000,000 ns = 1 s.

## DIAGNOSING COMMON PERFORMANCE PROBLEMS

**Problem: high CPU usage**
- Mode: cpu
- Look for: functions with high flat cpu time.
- Action: optimize the hot function or call it less.

**Problem: slow request / high latency**
- Mode: wall
- Look for: functions with high cum wall time.
- If [GVL blocked] is dominant → I/O or sleep is the bottleneck.
- If [GVL wait] is dominant → GVL contention; reduce GVL-holding work
  or move work to Ractors / child processes.

**Problem: GC pauses**
- Mode: cpu or wall
- Look for: [GC marking] and [GC sweeping] samples.
- High [GC marking] → too many live objects; reduce allocations.
- High [GC sweeping] → too many short-lived objects; reuse or pool.

**Problem: multithreaded app slower than expected**
- Mode: wall
- Look for: [GVL wait] time across threads.
- High [GVL wait] means threads are serialized on the GVL.

## READING COLLAPSED STACKS PROGRAMMATICALLY

Each line: `bottom_frame;...;top_frame weight_ns`

```ruby
File.readlines("profile.collapsed").each do |line|
  stack, weight = line.rpartition(" ").then { |s, _, w| [s, w.to_i] }
  frames = stack.split(";")
  # frames[0] is bottom (main), frames[-1] is leaf (hot)
end
```

## READING PPROF PROGRAMMATICALLY

Decompress + parse protobuf:

```ruby
require "zlib"; require "stringio"
raw = Zlib::GzipReader.new(StringIO.new(File.binread("profile.pb.gz"))).read
# raw is a protobuf binary; use google-protobuf gem or pprof tooling.
```

Or convert to text with pprof CLI:

    go tool pprof -text profile.pb.gz
    go tool pprof -top profile.pb.gz
    go tool pprof -flame profile.pb.gz

## ENVIRONMENT VARIABLES

Used internally by the CLI to pass options to the auto-started profiler:

    SPERF_ENABLED=1       Enable auto-start on require
    SPERF_OUTPUT=path     Output file path
    SPERF_FREQUENCY=hz    Sampling frequency
    SPERF_MODE=cpu|wall   Profiling mode
    SPERF_FORMAT=fmt      pprof, collapsed, or text
    SPERF_VERBOSE=1       Print statistics
    SPERF_SIGNAL=N|false  Timer signal number or 'false' for nanosleep (Linux only)
    SPERF_STAT=1          Enable stat mode (used by sperf stat)

## TIPS

- Default frequency (1000 Hz) works well for most cases; overhead is < 0.2%.
- For long-running production profiling, lower frequency (100-500) reduces overhead further.
- Profile representative workloads, not micro-benchmarks.
- Compare cpu and wall profiles to distinguish CPU-bound from I/O-bound.
- The verbose flag (-v) shows sampling overhead and top functions on stderr.
