# sperf

A safepoint-based sampling performance profiler for Ruby. Uses actual time deltas as sample weights to correct safepoint bias.

- Linux only, requires Ruby >= 4.0.0
- Output: pprof protobuf, collapsed stacks, or text report
- Modes: CPU time (per-thread) and wall time (with GVL/GC tracking)

## Quick Start

```bash
gem install sperf

# Performance summary
sperf stat ruby app.rb

# Profile to file
sperf record -o profile.pb.gz ruby app.rb
sperf record -m wall -o profile.pb.gz ruby server.rb

# View results
go tool pprof -http=:8080 profile.pb.gz
```

```ruby
require "sperf"

# Block form
Sperf.start(output: "profile.pb.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop
Sperf.start(frequency: 1000, mode: :wall)
# ...
data = Sperf.stop
Sperf.save("profile.pb.gz", data)
```

Run `sperf help` for full documentation (modes, formats, output interpretation, diagnostics guide).

## How It Works

### The Problem

Ruby's sampling profilers collect stack traces at **safepoints**, not at the exact timer tick. Traditional profilers assign equal weight to every sample, so if a safepoint is delayed 5ms, that delay is invisible.

### The Solution

sperf uses **time deltas as sample weights**:

```
Timer thread (pthread)           VM thread (postponed job)
─────────────────────           ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   sperf_sample_job()
                                      time_now = read_clock()
                                      weight = time_now - prev_time
                                      record(backtrace, weight)
```

If a safepoint is delayed, the sample carries proportionally more weight. The total weight equals the total time, accurately distributed across call stacks.

### GVL Event Tracking (wall mode)

sperf hooks GVL state transitions to capture off-GVL time:

- `[GVL blocked]` — time spent off-GVL (I/O, sleep, C extension)
- `[GVL wait]` — time waiting to reacquire the GVL (contention)

### GC Phase Tracking

- `[GC marking]` — time in GC mark phase
- `[GC sweeping]` — time in GC sweep phase

### Clock Sources

| Mode | Clock | What it measures |
|------|-------|------------------|
| `:cpu` (default) | Per-thread CPU clock (Linux ABI) | CPU cycles consumed (excludes sleep/I/O) |
| `:wall` | `CLOCK_MONOTONIC` | Real elapsed time (includes everything) |

## Output Formats

| Format | Extension | Use case |
|--------|-----------|----------|
| pprof (default) | `.pb.gz` | `go tool pprof`, speedscope |
| collapsed | `.collapsed` | FlameGraph, speedscope |
| text | `.txt` | Human/AI-readable report |

Format is auto-detected from extension, or set explicitly with `--format`.

## License

MIT
