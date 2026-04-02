# rperf Examples

A collection of examples to try out rperf's features.

## Prerequisites

```bash
# Build the C extension from the rperf project root
cd /path/to/rperf
rake compile
```

## 1. basic/ — CLI Profiling

Three workload scripts (~3 seconds each). All commands below assume you are in the rperf project root.

| Script | Workload | Recommended mode |
|---|---|---|
| `cpu_intensive.rb` | fib, prime sieve, sort | `-m cpu` |
| `io_and_threads.rb` | File I/O, thread contention, sleep | `-m wall` |
| `gc_heavy.rb` | Heavy object allocation and GC | `-m wall` (%GC labels) |

### Usage

```bash
# stat: execution time + profile summary
exe/rperf stat ruby examples/basic/cpu_intensive.rb
exe/rperf stat -m wall --report ruby examples/basic/gc_heavy.rb

# exec: stat + full report (flat/cumulative tables)
exe/rperf exec -m wall ruby examples/basic/io_and_threads.rb

# record: save to file
exe/rperf record -o profile.json.gz ruby examples/basic/cpu_intensive.rb
exe/rperf record -o profile.pb.gz ruby examples/basic/gc_heavy.rb

# report: open in viewer
exe/rperf report profile.json.gz          # browser flamegraph
exe/rperf report --top profile.json.gz    # top functions in terminal

# text output to stdout (no file needed)
exe/rperf record -p ruby examples/basic/cpu_intensive.rb
```

## 2. rack/ — Rack App + Viewer

A Rack app with the rperf viewer at `/rperf/`.

### Start

No gem install needed — uses `require_relative` to load rperf from the source tree.

```bash
rackup examples/rack/config.ru
```

1. Visit http://localhost:9292/ for the endpoint index
2. On boot, traffic is automatically generated and 3 snapshots are taken
3. Visit http://localhost:9292/rperf/ to explore the profile

#### Endpoints

| Path | Workload |
|---|---|
| `/cpu` | CPU-bound loop |
| `/io` | File I/O |
| `/gc` | GC-heavy allocation |
| `/sleep` | Sleep + CPU |
| `/mixed` | All of the above |
| `/snapshot` | Take a profiler snapshot |
| `/rperf/` | Profiler viewer UI |

#### Viewer tips

- **Flamegraph** tab: click to zoom into a subtree
- **Top** tab: per-function time (click column headers to sort)
- **Tags** tab: breakdown by label (endpoint, %GVL, %GC)
- **tagfocus**: regex filter on label values (e.g. `cpu` to show only `/cpu` requests)
- **tagignore**: checkboxes to exclude label values

## 3. rails/ — Rails App + Viewer + Load Generator

A minimal single-file Rails app.

### Start

Rails and Puma need to be installed. A Gemfile is provided:

```bash
cd examples/rails
bundle install
ruby app.rb
```

### Usage

1. On boot, traffic is automatically generated and 3 snapshots are taken
2. Visit http://localhost:3000/rperf/ to explore the profile

#### Endpoints

| Path | Workload |
|---|---|
| `/cpu` | Fibonacci (CPU-bound) |
| `/cpu?n=38` | Fibonacci with custom N |
| `/string` | String/regex processing |
| `/gc` | GC-heavy object churn |
| `/slow` | Simulated slow queries (sleep) |
| `/mixed` | Mixed workload |
| `/data` | JSON API |
| `/snapshot` | Take a profiler snapshot |
| `/rperf/` | Profiler viewer UI |

### Generate additional load

```bash
# In a separate terminal
ruby examples/rails/load.rb                          # default: 5 rounds
ruby examples/rails/load.rb http://localhost:3000 10  # 10 rounds
```

Each round sends 6 concurrent threads hitting all endpoints, then takes a snapshot. Use the Tags tab in the viewer to filter by `endpoint` label and see per-endpoint time breakdown.

## 4. rubybench — Profile ruby-bench benchmarks with rperf

You can profile benchmarks from [ruby-bench](https://github.com/ruby/ruby-bench) with rperf.

### Setup

Clone rubybench into the rperf project root and initialize the ruby-bench submodule:

```bash
cd /path/to/rperf
git clone https://github.com/rubybench/rubybench.git
cd rubybench
git submodule update --init benchmark/ruby-bench
```

### Profile a single benchmark

ruby-bench benchmarks can be run directly with `ruby benchmarks/xxx.rb`. The default harness runs many iterations (warmup + timed). Use `-Iharness-once` for a single iteration, which is usually enough for profiling.

All commands below assume you are in the ruby-bench directory:

```bash
cd rubybench/benchmark/ruby-bench

# Simple micro benchmarks (no gem dependencies)
rperf exec -m cpu ruby benchmarks/fib.rb
rperf exec -m cpu ruby benchmarks/nqueens.rb
rperf exec -m cpu ruby benchmarks/splay.rb
rperf exec -m wall ruby benchmarks/binarytrees/benchmark.rb

# Single iteration (faster, sufficient for profiling)
rperf exec -m cpu ruby -Iharness-once benchmarks/fib.rb
rperf exec -m cpu ruby -Iharness-once benchmarks/nqueens.rb

# Save to file
rperf record -o fib.json.gz -m cpu ruby -Iharness-once benchmarks/fib.rb
rperf report fib.json.gz

# Text output to stdout
rperf record -p -m cpu ruby benchmarks/fib.rb
```

### Macro benchmarks (require gem dependencies)

Benchmarks like railsbench have Gemfiles and need `bundle install` first.

```bash
cd benchmarks/railsbench && bundle install && cd ../..
rperf exec -m wall ruby -Iharness-once benchmarks/railsbench/benchmark.rb
rperf record -o railsbench.json.gz -m wall ruby -Iharness-once benchmarks/railsbench/benchmark.rb
rperf report railsbench.json.gz
```

Other macro benchmarks (`lobsters`, `activerecord`, `liquid-render`, etc.) work the same way:

```bash
cd benchmarks/activerecord && bundle install && cd ../..
rperf exec -m cpu ruby -Iharness-once benchmarks/activerecord/benchmark.rb

cd benchmarks/liquid-render && bundle install && cd ../..
rperf exec -m cpu ruby -Iharness-once benchmarks/liquid-render/benchmark.rb
```

### Dependency-free benchmarks (ready to use)

| Benchmark | Workload |
|---|---|
| `fib.rb` | Recursive fibonacci |
| `nqueens.rb` | N-Queens solver |
| `splay.rb` | Splay tree operations |
| `fannkuchredux/benchmark.rb` | Fannkuch-Redux |
| `nbody/benchmark.rb` | N-Body simulation |
| `sudoku.rb` | Sudoku solver |
| `30k_methods.rb` | 30,000 method definitions and calls |
| `30k_ifelse.rb` | 30,000 branches |
| `getivar.rb` | Instance variable reads |
| `setivar.rb` | Instance variable writes |
| `loops-times.rb` | Loops (Integer#times) |

### Tips

- **cpu vs wall**: Use `-m cpu` for CPU-bound benchmarks, `-m wall` for I/O or sleep to see %GVL/%GC labels
- **harness-once**: Runs a single iteration. Fast and sufficient for profiling
- **Default harness**: Warmup + multiple iterations. Better for measuring YJIT effects
- **pprof format**: Use `-o xxx.pb.gz` to save in pprof format for analysis with `go tool pprof`
