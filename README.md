<p align="center">
  <img src="docs/logo.svg" alt="rperf logo" width="260">
</p>

<h1 align="center">rperf</h1>

<p align="center">
  <strong>Know where your Ruby spends its time — accurately.</strong><br>
  A sampling profiler that corrects safepoint bias using real time deltas.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/rperf"><img src="https://img.shields.io/gem/v/rperf.svg" alt="Gem Version"></a>
  <img src="https://img.shields.io/badge/Ruby-%3E%3D%203.4.0-cc342d" alt="Ruby >= 3.4.0">
  <a href="https://ko1.github.io/rperf/docs/manual/"><img src="https://img.shields.io/badge/docs-manual-blue" alt="Manual"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  Built-in flamegraph viewer &nbsp;·&nbsp; CPU mode & wall mode (GVL + GC tracking)
</p>

<p align="center">
  <a href='https://ko1.github.io/rperf/'>Web site</a>,
  <a href='https://ko1.github.io/rperf/docs/manual/'>Online manual</a>,
  <a href='https://github.com/ko1/rperf'>GitHub repository</a>
</p>

## See It in Action

```bash
$ rperf exec ruby fib.rb

 Performance stats for 'ruby fib.rb':

         2,023.3 ms   user
             4.3 ms   sys
         2,001.8 ms   real

         2,000.3 ms 100.0%  [Rperf] CPU execution
             3.0 ms         [Ruby ] GC time (4 count: 2 minor, 2 major)
          48,741            [Ruby ] allocated objects
          27,034            [Ruby ] freed objects
               1            [Ruby ] detected threads
              16 MB         [OS   ] peak memory (maxrss)
           5,784            [OS   ] page faults (5,783 minor, 1 major)
              22            [OS   ] context switches (13 voluntary, 9 involuntary)
               0 MB         [OS   ] disk I/O (0 MB read, 0 MB write)

 Flat:
         1,998.4 ms  99.9%  Object#fibonacci (fib.rb)
             1.9 ms   0.1%  Module#method_added (<C method>)

 Cumulative:
         2,000.3 ms 100.0%  <main> (fib.rb)
         1,998.4 ms  99.9%  Object#fibonacci (fib.rb)
             1.9 ms   0.1%  Module#method_added (<C method>)

  1999 samples / 1999 triggers, 0.1% profiler overhead
```

## Quick Start

```bash
# Performance summary (wall mode, prints to stderr)
rperf stat ruby app.rb

# Record a profile to file
rperf record ruby app.rb                     # → rperf.json.gz (cpu mode, default)
rperf record -m wall ruby server.rb          # wall mode

# View results in browser (no external tools needed)
rperf report                                 # open rperf.json.gz in viewer
rperf report --top profile.json.gz           # print top functions to terminal

# Compare two profiles (requires Go)
rperf diff before.json.gz after.json.gz      # open diff in browser
```

On `rperf report`, you can see the profile result like this page: [rprof viewer](https://ko1.github.io/rperf/examples/cpu_intensive_profile.html)

### Ruby API

```ruby
require "rperf"

# Block form — profiles and saves to file
Rperf.start(output: "profile.json.gz", frequency: 500, mode: :cpu) do
  # code to profile
end

# Manual start/stop
Rperf.start(frequency: 1000, mode: :wall)
# ...
data = Rperf.stop
Rperf.save("profile.json.gz", data)
```

### In-browser Viewer

```ruby
# config.ru
require "rperf/viewer"
require "rperf/rack"

Rperf.start(mode: :wall, defer: true)
use Rperf::Viewer           # visit /rperf/ for flamegraph UI
use Rperf::RackMiddleware   # labels each request
run MyApp

# Snapshot every 60 minutes
Thread.new { loop { sleep 3600; Rperf::Viewer.instance&.take_snapshot! } }
```

> **Note:** `Rperf::Viewer` has no built-in authentication. In production, restrict access with your framework's auth mechanisms (e.g., route constraints in Rails). See the [manual](https://ko1.github.io/rperf/docs/manual/) for examples.

### Environment Variables

Profile without code changes (e.g., Rails):

```bash
RPERF_ENABLED=1 RPERF_MODE=wall ruby app.rb    # → rperf.json.gz
rperf report                                    # open in viewer
```

Run `rperf help` for full documentation, or see the [online manual](https://ko1.github.io/rperf/docs/manual/).

## Subcommands

Inspired by Linux `perf` — familiar subcommand interface for profiling workflows.

| Command | Description |
|---------|-------------|
| `rperf record` | Profile a command and save to file (default: `.json.gz`) |
| `rperf stat` | Profile a command and print summary to stderr |
| `rperf exec` | Profile a command and print full report to stderr |
| `rperf report` | Open viewer for `.json.gz`; wraps `go tool pprof` for `.pb.gz` (requires Go) |
| `rperf diff` | Compare two profiles (requires Go) |
| `rperf help` | Show full reference documentation |

## How It Works

### The Challenge: Safepoint Sampling

Most Ruby profilers (e.g., stackprof) use signal handlers to capture stack traces at the exact moment the timer fires. rperf takes a different approach — it samples at **safepoints** (VM checkpoints), which is safer (no async-signal-safety concerns, reliable access to VM state) but means the sample timing can be delayed. Without correction, this delay would skew the results.

### The Fix: Weight = Real Time

rperf uses **actual elapsed time as sample weights** — so delayed samples carry proportionally more weight, and the profile matches reality:

```
Timer (signal or thread)         VM thread (postponed job)
────────────────────────         ────────────────────────
  every 1/frequency sec:          at next safepoint:
    rb_postponed_job_trigger()  →   rperf_sample_job()
                                      time_now = read_clock()
                                      weight = time_now - prev_time
                                      record(backtrace, weight)
```

On Linux, the timer uses `timer_create` + signal delivery (no extra thread).
On other platforms, a dedicated pthread with `nanosleep` is used.

If a safepoint is delayed, the sample carries proportionally more weight. The total weight equals the total time, accurately distributed across call stacks.

### Modes

| Mode | Clock | What it measures |
|------|-------|------------------|
| `cpu` (default) | `CLOCK_THREAD_CPUTIME_ID` | CPU time consumed (excludes sleep/I/O) |
| `wall` | `CLOCK_MONOTONIC` | Real elapsed time (includes everything) |

Use `cpu` to find what consumes CPU. Use `wall` to find what makes things slow (I/O, GVL contention, GC).

### GVL and GC Labels (wall mode)

rperf hooks GVL and GC events to attribute non-CPU time. These are recorded as labels on samples rather than synthetic stack frames:

| Label | Meaning |
|-------|---------|
| `%GVL: blocked` | Off-GVL time (I/O, sleep, C extension releasing GVL) |
| `%GVL: wait` | Waiting to reacquire the GVL (contention) |
| `%GC: mark` | Time in GC mark phase |
| `%GC: sweep` | Time in GC sweep phase |

## Why rperf?

- **Accurate despite safepoints** — Safepoint sampling is *safer* (no async-signal-safety issues), but normally *inaccurate*. rperf compensates with real time-delta weights, so profiles faithfully reflect where time is actually spent.
- **See the whole picture** (wall mode) — GVL contention, off-GVL I/O, GC marking/sweeping — all attributed to the call stacks responsible, via sample labels.
- **Built-in viewer** — Flamegraph, Top, Tags tabs with interactive tag filtering. No external tools needed to analyze profiles.
- **Low overhead** — Signal-based timer on Linux (no extra thread). ~1–5 us per sample.
- **Zero code changes** — Profile any Ruby program via CLI or environment variables. Drop-in for Rails, too.
- **`perf`-like CLI** — `record`, `stat`, `report`, `diff` — if you know Linux perf, you already know rperf.

### Limitations

- **Method-level only** — no line-level granularity.
- **Ruby >= 3.4.0** — uses recent VM internals (postponed jobs, thread event hooks).
- **POSIX only** — Linux, macOS. No Windows.
- **No fork following** — profiling stops in fork(2) child processes (the child can start a new session).


## Output Formats

| Format | Extension | Viewer |
|--------|-----------|--------|
| JSON (default) | `.json.gz` | `rperf report` (built-in viewer), `Rperf.load`, any JSON tool |
| pprof | `.pb.gz` | `go tool pprof` (requires Go), speedscope |
| collapsed | `.collapsed` | FlameGraph, speedscope |
| text | `.txt` | any text viewer |

Format is auto-detected from extension, or set explicitly with `--format`.

## License

MIT
