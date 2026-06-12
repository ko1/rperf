# Quick Reference

## CLI cheat sheet

```bash
# Quick performance overview
rperf stat ruby my_app.rb

# Performance overview with profile tables
rperf stat --report ruby my_app.rb

# Full performance report (same as stat --report)
rperf exec ruby my_app.rb

# Record to default file (rperf.json.gz, json format, cpu mode)
rperf record ruby my_app.rb

# Record with options
rperf record -m wall -f 500 -o profile.pb.gz ruby my_app.rb

# Record and print text profile to stdout
rperf record -p ruby my_app.rb

# Record to text format
rperf record -o profile.txt ruby my_app.rb

# Record to collapsed stacks
rperf record -o profile.collapsed ruby my_app.rb

# Profile a preforking server (all workers)
rperf stat -m wall bundle exec unicorn

# Disable child process tracking
rperf stat --no-inherit ruby my_app.rb

# View profile in rperf viewer
rperf report

# Print top functions
rperf report --top profile.pb.gz

# Compare two profiles
rperf diff before.pb.gz after.pb.gz

# Full documentation
rperf help
```

## Ruby API cheat sheet

```ruby
require "rperf"

# Block form
data = Rperf.start(output: "profile.pb.gz", mode: :cpu) do
  # code to profile
end

# Manual form
Rperf.start(frequency: 1000, mode: :wall)
# ...
data = Rperf.stop

# Save to file
Rperf.save("profile.pb.gz", data)
Rperf.save("profile.collapsed", data)
Rperf.save("profile.txt", data)

# Snapshot (read data without stopping)
snap = Rperf.snapshot
Rperf.save("snap.pb.gz", snap)
snap = Rperf.snapshot(clear: true)  # reset after snapshot

# Deferred start + targeted profiling
Rperf.start(defer: true, mode: :wall)
Rperf.profile(endpoint: "/users") do
  # only this block is sampled
end
data = Rperf.stop

# Labels (annotate samples with context)
Rperf.label(request: "abc") do
  # samples inside get request="abc" label
end
Rperf.labels       # get current labels

# Rack middleware (labels requests by endpoint)
require "rperf/rack"
use Rperf::RackMiddleware                    # Rails: config.middleware.use Rperf::RackMiddleware
use Rperf::RackMiddleware, label_key: :route # custom label key

# Active Job (labels jobs by class name)
require "rperf/active_job"
class ApplicationJob < ActiveJob::Base
  include Rperf::ActiveJobMiddleware
end

# Sidekiq (labels jobs by worker class name)
require "rperf/sidekiq"
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add Rperf::SidekiqMiddleware
  end
end
```

## Environment variables

These are used internally by the CLI to configure the auto-started profiler:

| Variable | Values | Description |
|----------|--------|-------------|
| `RPERF_ENABLED` | `1` | Enable auto-start on require |
| `RPERF_OUTPUT` | path | Output file path |
| `RPERF_FREQUENCY` | integer | Sampling frequency in Hz |
| `RPERF_MODE` | `cpu`, `wall` | Profiling mode |
| `RPERF_FORMAT` | `json`, `pprof`, `collapsed`, `text` | Output format |
| `RPERF_VERBOSE` | `1` | Print statistics to stderr |
| `RPERF_STAT` | `1` | Enable stat mode output |
| `RPERF_STAT_REPORT` | `1` | Include profile tables in stat output |
| `RPERF_STAT_COMMAND` | string | Command string shown in stat output header |
| `RPERF_AGGREGATE` | `0` | Disable sample aggregation (return raw samples) |
| `RPERF_SIGNAL` | integer or `false` | Timer signal (Linux only): signal number, or `false` for nanosleep thread |
| `RPERF_DEFER` | `1` | Start with timer paused; use `Rperf.profile` to activate |
| `RPERF_ROOT_PROCESS` | PID string | Root process PID for multi-process session (set by CLI) |
| `RPERF_SESSION_DIR` | path | Session directory for multi-process profile collection (set by CLI) |
| `RPERF_TMPDIR` | path | Override base directory for session directories (default: `$XDG_RUNTIME_DIR` or system tmpdir) |

## Profiling mode comparison

| Aspect | cpu | wall |
|--------|-----|------|
| Clock | `CLOCK_THREAD_CPUTIME_ID` | `CLOCK_MONOTONIC` |
| I/O time | Not measured | `%GVL=blocked` label |
| Sleep time | Not measured | `%GVL=blocked` label |
| GVL contention | Not measured | `%GVL=wait` label |
| GC time | `%GC=mark`, `%GC=sweep` labels | `%GC=mark`, `%GC=sweep` labels |
| Best for | CPU hotspots | Latency analysis |

## Output format comparison

| Extension | Format | Tooling required |
|-----------|--------|-----------------|
| `.json.gz` (default) | JSON (rperf native) | None (`rperf report`) |
| `.pb.gz` | pprof protobuf | Go (`rperf report`) |
| `.collapsed` | Collapsed stacks | flamegraph.pl or speedscope |
| `.txt` | Text report | None |

## VM state labels

| Label | Value | Mode | Meaning |
|-------|-------|------|---------|
| `%GVL` | `blocked` | wall | Thread off-GVL (I/O, sleep, C ext) |
| `%GVL` | `wait` | wall | Thread waiting for GVL (contention) |
| `%GC` | `mark` | both | GC marking phase (wall time) |
| `%GC` | `sweep` | both | GC sweeping phase (wall time) |
| `%pid` | PID string | both | Child process ID (multi-process mode only) |

These labels are attached to samples alongside user labels. In pprof output, filter with `-tagfocus=%GVL=blocked`, `-tagroot=%GC`, `-tagfocus=%pid=1234`, etc.
