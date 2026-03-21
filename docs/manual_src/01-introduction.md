# Introduction

## What is sperf?

sperf is a safepoint-based sampling performance profiler for Ruby. It helps you find where your Ruby program spends its time — whether that's CPU computation, I/O waits, GVL contention, or garbage collection.

Unlike traditional sampling profilers that count samples uniformly, sperf uses actual time deltas (in nanoseconds) as weights for each sample. This corrects the safepoint bias problem that affects all Ruby sampling profilers, producing more accurate results.

sperf is inspired by Linux [perf](#cite:demelo2010), providing a familiar CLI interface with subcommands like `record`, `stat`, and `report`.

## Why another profiler?

Ruby already has profiling tools like [stackprof](#cite:stackprof). So why sperf?

### The safepoint bias problem

All Ruby sampling profilers must collect backtraces at safepoints — points where the VM is in a consistent state. When a timer fires between safepoints, the actual sample is delayed until the next safepoint. Traditional profilers count each sample equally (weight = 1), which means a sample that was delayed by a long-running C method gets the same weight as one taken immediately.

This is the [safepoint bias](#cite:mytkowicz2010) problem: functions that happen to be running when the thread reaches a safepoint appear more often than they should, while functions between safepoints are under-represented.

```mermaid
sequenceDiagram
    participant Timer
    participant VM
    participant Profiler

    Timer->>VM: Signal (t=0ms)
    Note over VM: Running C method...<br/>cannot stop yet
    VM->>Profiler: Safepoint reached (t=3ms)
    Note over Profiler: Traditional: weight = 1<br/>sperf: weight = 3ms
    Timer->>VM: Signal (t=1ms)
    VM->>Profiler: Safepoint reached (t=1ms)
    Note over Profiler: Traditional: weight = 1<br/>sperf: weight = 1ms
```

sperf solves this by recording `clock_now - clock_prev` as the weight of each sample. A sample delayed by 3ms gets 3x the weight of a 1ms sample, accurately reflecting where time was actually spent.

### Other advantages

- **GVL and GC awareness**: In wall mode, sperf tracks time spent blocked off the GVL, waiting to reacquire the GVL, and in GC marking/sweeping phases — each as distinct synthetic frames.
- **perf-like CLI**: The `sperf stat` command gives you a quick performance overview (like `perf stat`), while `sperf record` + `sperf report` gives you detailed profiling.
- **Standard output**: sperf outputs pprof protobuf format, compatible with Go's `pprof` tool ecosystem, as well as collapsed stacks for [flame graphs](#cite:gregg2016) and speedscope.
- **Low overhead**: Default 1000 Hz sampling adds < 0.2% overhead, suitable for production use.

## Requirements

- Ruby >= 3.4.0
- POSIX system (Linux or macOS)
- Go (optional, for `sperf report` and `sperf diff` subcommands)

## Quick start

Profile a Ruby script and view the results:

```bash
# Install sperf
gem install sperf

# Quick performance overview
sperf stat ruby my_app.rb

# Record a profile and view it interactively
sperf record ruby my_app.rb
sperf report
```

Or use sperf from Ruby code:

```ruby
require "sperf"

Sperf.start(output: "profile.pb.gz") do
  # code to profile
end
```
