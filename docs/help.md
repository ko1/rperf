# rperf - safepoint-based sampling performance profiler for Ruby

## OVERVIEW

rperf profiles Ruby programs by sampling at safepoints and using actual
time deltas (nanoseconds) as weights to correct safepoint bias.
POSIX systems (Linux, macOS). Requires Ruby >= 3.4.0.

## CLI USAGE

    rperf record [options] command [args...]
    rperf stat [options] command [args...]
    rperf exec [options] command [args...]
    rperf report [options] [file]
    rperf help

### record: Profile and save to file.

    -o, --output PATH       Output file (default: rperf.json.gz)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: cpu)
    --format FORMAT         json, pprof, collapsed, or text (default: auto from extension)
    -p, --print             Print text profile to stdout
                            (same as --format=text --output=/dev/stdout)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    --no-inherit            Do not profile forked/spawned child processes
    --no-aggregate          Disable C-level sample aggregation (raw per-sample data)
    -v, --verbose           Print sampling statistics to stderr

### stat: Run command and print performance summary to stderr.

Uses wall mode by default. No file output by default.

    -o, --output PATH       Also save profile to file (default: none)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: wall)
    --report                Include flat/cumulative profile tables in output
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    --no-inherit            Do not profile forked/spawned child processes
    --no-aggregate          Disable C-level sample aggregation (raw per-sample data)
    -v, --verbose           Print additional sampling statistics

Shows: user/sys/real time, time breakdown (CPU execution, GVL blocked,
GVL wait, GC marking, GC sweeping), GC/memory/OS stats, and profiler overhead.
Lines are prefixed: `[Rperf]` for sampling-derived data, `[Ruby ]` for
runtime info, `[OS   ]` for OS-level info.
Use --report to add flat and cumulative top-50 function tables.

When child processes are profiled (default), the stat output shows
aggregated data from all processes and includes a "Ruby processes profiled"
count. Use --no-inherit to disable child process tracking.

### exec: Run command and print full profile report to stderr.

Like `stat --report`. Uses wall mode by default. No file output by default.

    -o, --output PATH       Also save profile to file (default: none)
    -f, --frequency HZ      Sampling frequency in Hz (default: 1000)
    -m, --mode MODE         cpu or wall (default: wall)
    --signal VALUE          Timer signal (Linux only): signal number, or 'false'
                            for nanosleep thread (default: auto)
    --no-inherit            Do not profile forked/spawned child processes
    --no-aggregate          Disable C-level sample aggregation (raw per-sample data)
    -v, --verbose           Print additional sampling statistics

Shows: user/sys/real time, time breakdown, GC/memory/OS stats, profiler overhead,
and flat/cumulative top-50 function tables.

### report: Open profile viewer or go tool pprof.

    --top                   Print top functions by flat time
    --text                  Print text report
    --html                  Output static HTML viewer to stdout

Default (no flag): opens interactive web UI in browser.
Default file: rperf.json.gz

`--html` generates an HTML file with profile data embedded inline.
No server is needed — open it directly in a browser. d3 and
d3-flamegraph are loaded from CDN, so an internet connection is
required on first viewing. Useful for sharing or hosting on static
sites (e.g., GitHub Pages).

    rperf report --html profile.json.gz > report.html

### diff: Compare two pprof profiles (target - base). Requires Go.

    --top                   Print top functions by diff
    --text                  Print text diff report

Default (no flag): opens diff in browser.

### Multi-process profiling

By default, rperf profiles forked and spawned Ruby child processes.
Profiles from all processes are merged into a single output. Each child
process's samples are tagged with a `%pid` label for per-process filtering.

    # Profile a preforking server (Unicorn, Puma, etc.)
    rperf stat -m wall bundle exec unicorn
    rperf record -m wall -o profile.json.gz bundle exec unicorn

    # Profile with fork
    rperf stat ruby -e '4.times { fork { work } }; Process.waitall'

    # Disable child process tracking
    rperf stat --no-inherit ruby app.rb

How it works:

- On fork: `Process._fork` hook restarts profiling in the child and sets
  a `%pid` label. When the child exits, its profile is saved to a
  temporary session directory.
- On spawn/system: The spawned Ruby process inherits `RUBYOPT=-rrperf`
  and `RPERF_SESSION_DIR`. It auto-starts profiling and writes its
  profile to the session directory.
- When the root process exits, it aggregates all profiles from the
  session directory into a single output (stat report or file).
- The session directory is cleaned up after aggregation.

Limitations:

- Daemon children (Process.daemon) that outlive the parent will have
  their profiles lost, since the parent aggregates and cleans up the
  session directory at exit.
- Cross-process snapshots (Rperf.snapshot) are not supported; snapshots
  only cover the current process.
- Only Ruby child processes are profiled; non-Ruby children (shell
  scripts, Python, etc.) are not affected.
- Child processes that use rperf independently (Rperf.start in their
  own code) will conflict with the inherited auto-start session.
  Such programs should clear RPERF_ENABLED from their environment
  before requiring rperf.

### Examples

    rperf record ruby app.rb
    rperf record -o profile.pb.gz ruby app.rb
    rperf record -m wall -f 500 -o profile.pb.gz ruby server.rb
    rperf record -o profile.collapsed ruby app.rb
    rperf record -o profile.txt ruby app.rb
    rperf record -p ruby app.rb
    rperf stat ruby app.rb
    rperf stat --report ruby app.rb
    rperf stat -o profile.pb.gz ruby app.rb
    rperf stat -m wall bundle exec unicorn
    rperf stat --no-inherit ruby app.rb
    rperf exec ruby app.rb
    rperf exec -m cpu ruby app.rb
    rperf report
    rperf report --top profile.pb.gz
    rperf diff before.pb.gz after.pb.gz
    rperf diff --top before.pb.gz after.pb.gz

## RUBY API

```ruby
require "rperf"

# Block form (recommended) — profiles the block and writes to file
Rperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop — returns data hash for programmatic use
Rperf.start(frequency: 1000, mode: :wall)
# ... code to profile ...
data = Rperf.stop

# Save data to file later
Rperf.save("profile.pb.gz", data)
Rperf.save("profile.collapsed", data)
Rperf.save("profile.txt", data)
```

### Rperf.start parameters

    frequency:  Sampling frequency in Hz (Integer, default: 1000)
    mode:       :cpu or :wall (Symbol, default: :cpu)
    output:     File path to write on stop (String or nil)
    verbose:    Print statistics to stderr (true/false, default: false)
    format:     :json, :pprof, :collapsed, :text, or nil for auto-detect (Symbol or nil)
    defer:      Start with timer paused; use Rperf.profile to activate (default: false)
    inherit:    Child process tracking: :fork (default), true (fork+spawn), false (none)
                Note: CLI defaults to true (--no-inherit to disable)
    signal:     Timer signal (Linux only): nil (default, auto), false (use nanosleep),
                or a signal number (Integer)
    aggregate:  Aggregate samples in C (default: true). false returns raw per-sample data

### Rperf.stop return value

nil if profiler was not running; otherwise a Hash:

```ruby
{ mode: :cpu,                      # or :wall
  frequency: 500,
  sampling_count: 1234,
  sampling_time_ns: 56789,
  detected_thread_count: 4,        # threads seen during profiling
  start_time_ns: 17740...,         # CLOCK_REALTIME epoch nanos
  duration_ns: 10000000,           # profiling duration in nanos
  aggregated_samples: [                  # when aggregate: true (default)
    [frames, weight, seq, label_set_id], #   frames: [[path, label], ...] deepest-first
    ...                                  #   weight: Integer (nanoseconds, merged per unique stack)
  ],                                     #   seq: Integer (thread sequence, 1-based)
                                         #   label_set_id: Integer (0 = no labels)
  label_sets: [{}, {request: "abc"}, ...], # label set table (index = label_set_id)
  # --- OR ---
  raw_samples: [                   # when aggregate: false
    [frames, weight, seq, label_set_id], # one entry per timer sample (not merged)
    ...
  ] }
```

### Rperf.snapshot(clear: false)

Returns a snapshot of the current profiling data without stopping.
Only works in aggregate mode (the default). Returns nil if not profiling.

When `clear: true` is given, resets aggregated data after taking the snapshot.
This enables interval-based profiling where each snapshot covers only the
period since the last clear.

```ruby
Rperf.start(frequency: 1000)
# ... work ...
snap = Rperf.snapshot         # read data without stopping
Rperf.save("snap.pb.gz", snap)
# ... more work ...
data = Rperf.stop
```

Interval-based usage:

```ruby
Rperf.start(frequency: 1000)
loop do
  sleep 10
  snap = Rperf.snapshot(clear: true)  # each snapshot covers the last 10s
  Rperf.save("profile-#{Time.now.to_i}.pb.gz", snap)
end
```

### Rperf.label(**labels, &block)

Attaches key-value labels to the current thread's samples. Labels appear
in pprof sample labels, enabling per-context filtering (e.g., per-request).
If profiling is not running, labels are silently ignored (no error).

```ruby
# Block form — labels are restored when the block exits
Rperf.label(request: "abc-123", endpoint: "/api/users") do
  handle_request   # samples inside get these labels
end
# labels are restored to previous state here

# Without block — labels persist until changed
Rperf.label(request: "abc-123")

# Merge — new labels merge with existing ones
Rperf.label(phase: "db")      # adds phase, keeps request

# Delete a key — set value to nil
Rperf.label(request: nil)     # removes request key

# Nested blocks — each block restores its entry state
Rperf.label(request: "abc") do
  Rperf.label(phase: "db") do
    Rperf.labels  #=> {request: "abc", phase: "db"}
  end
  Rperf.labels    #=> {request: "abc"}
end
Rperf.labels      #=> {}
```

In pprof output, use labels for filtering and grouping:

    go tool pprof -tagfocus=request=abc-123 profile.pb.gz
    go tool pprof -tagroot=request profile.pb.gz
    go tool pprof -tagleaf=request profile.pb.gz

### Rperf.start with defer: true

With `defer: true`, the profiler infrastructure is set up but the sampling
timer does not start. Use `Rperf.profile` to activate the timer for specific
sections. Outside `profile` blocks, the timer is disarmed and overhead is zero.

Note: the timer is process-wide, not per-thread. While a `profile` block is
active on one thread, other threads running at the same time will also be
sampled. Their samples carry their own labels (not the calling thread's labels),
so they can be distinguished in the profile. This design is intentional: it
provides complete visibility into what the process was doing during profiled
sections, including GVL contention and background work.

### Rperf.profile(**labels, &block)

Activates the sampling timer for the block duration and applies labels to
the current thread. Designed for use with `start(defer: true)`.

```ruby
Rperf.start(defer: true, mode: :wall)

Rperf.profile(endpoint: "/users") do
  handle_request   # sampled with endpoint="/users"
end
# timer paused — zero overhead

data = Rperf.stop
```

Nesting is supported: timer stays active until the outermost block exits.
Also works with `start(defer: false)` — applies labels only (timer already
running). Raises `RuntimeError` if not started, `ArgumentError` without block.

### Rperf.labels

Returns the current thread's labels as a Hash. Empty hash if none set.

### Rperf.save(path, data, format: nil)

Writes data to path. format: :json, :pprof, :collapsed, or :text.
nil auto-detects from extension.

### Rperf::RackMiddleware (Rack)

Labels samples with the request endpoint. Requires `require "rperf/rack"`.

```ruby
# Rails
Rails.application.config.middleware.use Rperf::RackMiddleware

# Sinatra
use Rperf::RackMiddleware
```

The middleware uses `Rperf.profile` to activate timer and set labels.
Start profiling separately. Option: `label_key:` (default: `:endpoint`).

### Rperf::ActiveJobMiddleware

Labels samples with the job class name. Requires `require "rperf/active_job"`.

```ruby
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end
```

### Rperf::SidekiqMiddleware

Labels samples with the worker class name. Requires `require "rperf/sidekiq"`.

```ruby
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

### Rperf::Viewer (Rack middleware)

In-browser profiling UI with flamegraph, top table, and tag breakdown.
Requires `require "rperf/viewer"`.

**Security note**: Rperf::Viewer has no built-in authentication and exposes
profiling data (including stack traces and label values) to anyone who can
reach the endpoint. In production, always restrict access using your
framework's authentication — see "Access control" below. The UI loads
d3.js and d3-flame-graph from CDNs (cdnjs.cloudflare.com, cdn.jsdelivr.net).

```ruby
# config.ru or Rails config
require "rperf/viewer"
use Rperf::Viewer                         # mount at /rperf/ (default)
use Rperf::Viewer, path: "/profiler"      # custom mount path
use Rperf::Viewer, max_snapshots: 12      # keep fewer snapshots (default: 24)
```

Take snapshots via `Rperf::Viewer.instance.take_snapshot!` or
`Rperf::Viewer.instance.add_snapshot(data)`.

#### Typical setup with RackMiddleware and periodic snapshots

```ruby
require "rperf/viewer"
require "rperf/rack"

Rperf.start(mode: :wall, frequency: 999, defer: true)
use Rperf::Viewer
use Rperf::RackMiddleware
run MyApp

# Take a snapshot every 60 minutes in a background thread
Thread.new do
  loop do
    sleep 60 * 60
    Rperf::Viewer.instance&.take_snapshot!
  end
end
```

Visit `/rperf/` in a browser. Snapshots accumulate automatically
(up to `max_snapshots`, oldest are discarded). You can also trigger
a snapshot manually via an endpoint or console:

```ruby
Rperf::Viewer.instance.take_snapshot!
```

#### Access control

Rperf::Viewer has no built-in authentication. Restrict access using
your framework's existing mechanisms:

```ruby
# Rails: route constraint (e.g., admin-only)
# config/routes.rb
require "rperf/viewer"
constraints ->(req) { req.session[:admin] } do
  mount Rperf::Viewer.new(nil, path: ""), at: "/rperf"
end
```

#### UI tabs

- **Flamegraph** — Interactive flamegraph (d3-flame-graph). Click to zoom.
- **Top** — Flat/cumulative weight table. Click column headers to sort.
- **Tags** — Label key/value breakdown with weight bars. Click a row to
  set tagfocus and switch to Flamegraph.

#### Filtering controls

- **tagfocus** — Regex matched against label values. Press Enter to apply.
- **tagignore** — Dropdown checkboxes. Select `key = (none)` to exclude
  samples without that key (e.g., background threads without `endpoint`).
- **tagroot** — Dropdown checkboxes for label keys. Checked keys are
  prepended as root frames (e.g., `[endpoint: GET /users]`).
- **tagleaf** — Same as tagroot but appended as leaf frames.

Tag keys are sorted alphabetically (`%`-prefixed VM state keys appear first).

## PROFILING MODES

- **cpu** — Measures per-thread CPU time via Linux thread clock.
  Use for: finding functions that consume CPU cycles.
  Ignores time spent sleeping, in I/O, or waiting for GVL.

- **wall** — Measures wall-clock time (CLOCK_MONOTONIC).
  Use for: finding where wall time goes, including I/O, sleep, GVL
  contention, and off-CPU waits.
  Includes VM state labels (see below).

## OUTPUT FORMATS

### json (default) — rperf native format

Gzip-compressed JSON representation of the internal data hash
(the same hash returned by `Rperf.stop` / `Rperf.snapshot` — see
"Return value" above for the full structure).
Preserves all data including labels, VM state, thread info, and statistics.
Readable by non-Ruby tools (Python, jq, etc.).
Extension convention: `.json.gz`
View with: `rperf report` (opens rperf viewer in browser, no Go required).
Load programmatically: `data = Rperf.load("rperf.json.gz")`

### pprof

Gzip-compressed protobuf. Standard pprof format.
Extension convention: `.pb.gz`
View with: `go tool pprof`, pprof-rs, speedscope, or `rperf report` (requires Go).

Embedded metadata:

    comment         rperf version, mode, frequency, Ruby version
    time_nanos      profile collection start time (epoch nanoseconds)
    duration_nanos  profile duration (nanoseconds)
    doc_url         link to this documentation

Sample labels:

    thread_seq      thread sequence number (1-based, assigned per profiling session)
    <user labels>   custom key-value labels set via Rperf.label()

View comments: `go tool pprof -comments profile.pb.gz`

Group by thread: `go tool pprof -tagroot=thread_seq profile.pb.gz`

Filter by label: `go tool pprof -tagfocus=request=abc-123 profile.pb.gz`

Group by label (root): `go tool pprof -tagroot=request profile.pb.gz`

Group by label (leaf): `go tool pprof -tagleaf=request profile.pb.gz`

Exclude by label: `go tool pprof -tagignore=request=healthcheck profile.pb.gz`

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
               820.3 ms  53.8%  Array#each (app/models/user.rb)
               312.1 ms  20.5%  JSON.parse (lib/json/parser.rb)
               ...

     Cumulative:
             1,401.2 ms  92.0%  UsersController#index (app/controllers/users_controller.rb)
               ...

### Format auto-detection

Format is auto-detected from the output file extension:

    .json.gz    → json (rperf native, default)
    .pb.gz      → pprof
    .collapsed  → collapsed
    .txt        → text

The `--format` flag (CLI) or `format:` parameter (API) overrides auto-detect.

## VM STATE LABELS

rperf tracks GVL and GC states as **labels** (tags) on samples, not as
stack frames. The C extension records a VM state per sample, and the Ruby
layer merges it into the sample's label set using reserved keys `%GVL`
and `%GC`.

In wall mode, GVL state labels are recorded:

- **%GVL=blocked** — The thread was off-GVL (I/O, sleep, C extension
  releasing GVL). Attributed to the stack at SUSPENDED.
- **%GVL=wait** — The thread was waiting to reacquire the GVL after
  becoming ready. Indicates GVL contention. Same stack.

In both modes, GC state labels are recorded:

- **%GC=mark** — Time spent in GC marking phase (wall time).
- **%GC=sweep** — Time spent in GC sweeping phase (wall time).

These labels appear in `label_sets` (e.g., `{:"%GVL" => "blocked"}`,
`{:"%GC" => "mark"}`) and are written into pprof sample labels.

To add VM state as frames in flamegraphs, use pprof tag options:

    go tool pprof -tagleaf=%GVL profile.pb.gz
    go tool pprof -tagroot=%GC profile.pb.gz

To filter by VM state:

    go tool pprof -tagfocus=%GVL=blocked profile.pb.gz
    go tool pprof -tagfocus=%GC=mark profile.pb.gz

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
- If %GVL=blocked is dominant → I/O or sleep is the bottleneck.
  Filter: `go tool pprof -tagfocus=%GVL=blocked profile.pb.gz`
- If %GVL=wait is dominant → GVL contention; reduce GVL-holding work
  or move work to Ractors / child processes.
  Filter: `go tool pprof -tagfocus=%GVL=wait profile.pb.gz`

**Problem: GC pauses**
- Mode: cpu or wall
- Look for: samples with %GC=mark and %GC=sweep labels.
  Filter: `go tool pprof -tagfocus=%GC profile.pb.gz`
- High %GC=mark → too many live objects; reduce allocations.
- High %GC=sweep → too many short-lived objects; reuse or pool.

**Problem: multithreaded app slower than expected**
- Mode: wall
- Look for: samples with %GVL=wait label across threads.
  Filter: `go tool pprof -tagfocus=%GVL=wait profile.pb.gz`
- High %GVL=wait means threads are serialized on the GVL.

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

    RPERF_ENABLED=1       Enable auto-start on require
    RPERF_OUTPUT=path     Output file path
    RPERF_FREQUENCY=hz    Sampling frequency
    RPERF_MODE=cpu|wall   Profiling mode
    RPERF_FORMAT=fmt      json, pprof, collapsed, or text
    RPERF_VERBOSE=1       Print statistics
    RPERF_SIGNAL=N|false  Timer signal number or 'false' for nanosleep (Linux only)
    RPERF_STAT=1          Enable stat mode (used by rperf stat)
    RPERF_STAT_REPORT=1   Include profile tables in stat output

## TIPS

- Default frequency (1000 Hz) works well for most cases; overhead is < 0.2%.
- For long-running production profiling, lower frequency (100-500) reduces overhead further.
- Profile representative workloads, not micro-benchmarks.
- Compare cpu and wall profiles to distinguish CPU-bound from I/O-bound.
- The verbose flag (-v) shows sampling overhead and top functions on stderr.
