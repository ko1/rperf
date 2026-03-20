# sprof

A safepoint-based sampling profiler for Ruby that uses actual time deltas as sample weights to correct safepoint bias. Outputs [pprof](https://github.com/google/pprof) format.

## The Problem with Safepoint-Based Sampling

Ruby's sampling profilers can only inspect thread state at **safepoints** -- points where the VM is in a consistent state (e.g., between bytecode instructions, at method calls). A timer fires at regular intervals, but the actual stack trace is collected at the next safepoint, not at the exact moment the timer fires. This introduces **safepoint bias**: code that executes long stretches without hitting a safepoint (e.g., C extensions, tight native loops) is underrepresented, while code near frequent safepoints is overrepresented.

Traditional sampling profilers assign equal weight (1 sample = 1 interval) to every sample regardless of when the safepoint actually occurred. If the timer fires at T=0 but the safepoint arrives at T=5ms, the 5ms delay is invisible -- the sample is counted the same as one collected instantly.

## How sprof Solves This

sprof uses **time deltas as sample weights** instead of counting samples uniformly.

### Sampling Architecture

```
Timer thread (pthread)           VM thread (postponed job)
─────────────────────           ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   sprof_sample_job()
                                      current thread only:
                                        time_now = read_clock()
                                        weight = time_now - prev_time
                                        prev_time = time_now
                                        record(backtrace, weight)
```

1. A **timer thread** (native pthread) fires `rb_postponed_job_trigger()` at the configured frequency (default: 100 Hz)
2. At the next safepoint, the VM executes the **sampling callback** as a postponed job on the current thread (GVL holder)
3. The callback:
   - Reads the current clock value (CPU time or wall time, depending on mode)
   - Computes `weight = current_time - previous_time` (nanoseconds elapsed since last sample)
   - Captures the stack trace via `rb_profile_thread_frames()`
   - Stores the sample with the computed weight

The key insight: **the weight is not the timer interval, but the actual time elapsed**. If a safepoint is delayed by 5ms, the sample carries 5ms of weight. If two safepoints are close together, the sample carries a small weight. The total weight across all samples equals the total time spent, accurately distributed across the observed call stacks.

### GVL Event Tracking (wall mode)

In addition to timer-based sampling, sprof hooks GVL state transitions to capture time spent off-GVL and waiting for the GVL:

```
RESUMED ──(GVL held, timer samples)──→ SUSPENDED ──(off-GVL)──→ READY ──(GVL wait)──→ RESUMED
            normal samples                normal sample      [GVL blocked]           [GVL wait]
```

- **SUSPENDED**: Records a normal sample with the current backtrace, saves the stack for reuse
- **READY**: Records wall timestamp only (may not have GVL)
- **RESUMED**: Records `[GVL blocked]` (off-GVL time) and `[GVL wait]` (GVL contention time) samples using the saved stack from SUSPENDED

These synthetic frames appear in the pprof output, showing which code caused GVL releases and how long threads waited to reacquire the GVL. GVL event samples are only recorded in wall mode (CPU time doesn't advance while off-GVL).

### GC Phase Tracking

sprof hooks GC enter/exit events to track time spent in garbage collection:

- `[GC marking]`: Time spent in GC mark phase
- `[GC sweeping]`: Time spent in GC sweep phase

Each GC chunk is recorded as a sample with the backtrace of the code that triggered GC, plus a synthetic `[GC marking]` or `[GC sweeping]` leaf frame. Weight is wall time regardless of profiling mode.

### Clock Sources

| Mode | Clock | Scope | What it measures |
|------|-------|-------|------------------|
| `:cpu` (default) | `clock_gettime(thread_cputime_id)` | Per-thread | CPU time consumed by the thread (excludes sleep, I/O wait) |
| `:wall` | `clock_gettime(CLOCK_MONOTONIC)` | Global | Real elapsed time (includes sleep, I/O wait, scheduling delays) |

In **cpu mode**, per-thread CPU clocks are read via the Linux kernel ABI (`~tid << 3 | 6`), with the native TID cached per-thread to avoid repeated syscalls. In **wall mode**, a single `CLOCK_MONOTONIC` read is used per sample.

### Per-Thread State

Each Ruby thread has per-thread data stored via `rb_internal_thread_specific_key`:
- `prev_cpu_ns` / `prev_wall_ns`: Previous clock values for weight computation
- GVL state: timestamps and saved stack for SUSPENDED/READY/RESUMED tracking
- Native TID: cached at first use for CPU time reads

Thread data is created on first event (RESUMED or SUSPENDED) via `sprof_thread_data_create()`. Thread exit cleanup is handled by a `RUBY_INTERNAL_THREAD_EVENT_EXITED` hook.

### Output

At stop time, the collected samples (stack + weight pairs) are:
1. Frame VALUEs resolved to strings (`rb_profile_frame_full_label`, `rb_profile_frame_path`)
2. Synthetic frames prepended for GVL/GC samples
3. Merged by identical stack traces (weights summed) in the pprof encoder
4. Encoded into [pprof protobuf format](https://github.com/google/pprof/blob/main/proto/profile.proto) using a hand-written encoder (no protobuf dependency)
5. Gzip-compressed and written to a `.pb.gz` file

The output is directly viewable with `go tool pprof`.

## Installation

```bash
gem install sprof
```

Requires Ruby >= 4.0.0 (Linux only; uses Linux-specific thread CPU clock ABI).

## Usage

### Ruby API

```ruby
require "sprof"

# Block form (auto-stop, optional save)
Sprof.start(output: "profile.pb.gz", frequency: 100, mode: :cpu) do
  # code to profile
end

# Block form without save (returns data hash)
data = Sprof.start(frequency: 100, mode: :wall) do
  # code to profile
end

# Manual start/stop
Sprof.start(frequency: 100, mode: :wall, output: "profile.pb.gz")
# ... code to profile ...
data = Sprof.stop  # saves to output path and returns data
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `frequency:` | `100` | Sampling frequency in Hz (1-1000000) |
| `mode:` | `:cpu` | `:cpu` for CPU time, `:wall` for wall time |
| `output:` | `nil` | Output file path (saves on stop if set) |
| `verbose:` | `false` | Print sampling statistics to stderr |

### CLI

```bash
# Profile any Ruby command
sprof exec ruby my_app.rb
sprof -o profile.pb.gz -f 100 exec ruby my_app.rb

# View results
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
```

| Flag | Default | Description |
|------|---------|-------------|
| `-o PATH` | `sprof.data` | Output file |
| `-f HZ` | `100` | Sampling frequency |
| `-m MODE` | `cpu` | Profiling mode: `cpu` or `wall` |
| `-v` | off | Print sampling statistics |

### Environment Variables

For use without code changes (e.g., profiling Rails):

```bash
SPROF_ENABLED=1 SPROF_MODE=wall SPROF_FREQUENCY=100 SPROF_OUTPUT=profile.pb.gz ruby app.rb
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SPROF_ENABLED` | - | Set to `"1"` to enable |
| `SPROF_MODE` | `"cpu"` | `"cpu"` or `"wall"` |
| `SPROF_FREQUENCY` | `100` | Sampling frequency in Hz |
| `SPROF_OUTPUT` | `"sprof.data"` | Output file path |
| `SPROF_VERBOSE` | - | Set to `"1"` to print stats |

## When to Use cpu vs wall Mode

- **cpu mode**: Use when you want to find what code is consuming CPU cycles. Sleep, I/O waits, mutex contention, and GVL waits are excluded. Results are stable regardless of system load.
- **wall mode**: Use when you want to find what code is slow from the user's perspective. Includes sleep, I/O, blocking calls, and scheduling delays. Also shows `[GVL blocked]` and `[GVL wait]` synthetic frames for diagnosing GVL contention.

## License

MIT
