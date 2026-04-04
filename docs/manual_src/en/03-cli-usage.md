# CLI Usage

rperf provides a perf-like command-line interface with five main subcommands: `record`, `stat`, `exec`, `report`, and `diff`.

## rperf stat

[`rperf stat`](#index:rperf stat) is the quickest way to get a performance overview. It runs your command with [wall](#index:wall mode)-mode profiling and prints a summary to stderr.

```bash
rperf stat ruby my_app.rb
```

### Example: CPU-bound program

Here is a simple Fibonacci computation:

```ruby
# fib.rb
def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end
fib(35)
```

Running `rperf stat`:

```bash
rperf stat ruby fib.rb
```

```
 Performance stats for 'ruby fib.rb':

           744.4 ms   user
            32.0 ms   sys
           491.0 ms   real

           481.0 ms 100.0%  [Rperf] CPU execution
            12.0 ms         [Ruby ] GC time (9 count: 6 minor, 3 major)
         154,468            [Ruby ] allocated objects
          66,596            [Ruby ] freed objects
              25 MB         [OS   ] peak memory (maxrss)
              31            [OS   ] context switches (10 voluntary, 21 involuntary)
               0 MB         [OS   ] disk I/O (0 MB read, 0 MB write)

  481 samples / 481 triggers, 0.1% profiler overhead
```

The output tells you:

- **user/sys/real**: Standard timing (like the `time` command)
- **`[Rperf]` lines**: Sampling-derived time breakdown — CPU execution, GVL blocked (I/O/sleep), GVL wait (contention), GC marking, GC sweeping
- **`[Ruby ]` lines**: Runtime statistics — GC count, allocated/freed objects, YJIT ratio (if enabled)
- **`[OS   ]` lines**: OS statistics — peak memory, context switches, disk I/O

Use `--report` to add flat and cumulative top-50 function tables to the output.

### Example: Mixed CPU and I/O

```ruby
# mixed.rb
def cpu_work(n)
  sum = 0
  n.times { |i| sum += i * i }
  sum
end

def io_work
  sleep(0.05)
end

5.times do
  cpu_work(500_000)
  io_work
end
```

Running `rperf stat`:

```bash
rperf stat ruby mixed.rb
```

Because `stat` always uses wall mode, you can see how time is divided between CPU and I/O. The `[Rperf] GVL blocked` line shows time spent sleeping/in I/O, while `[Rperf] CPU execution` shows compute time.

### stat options

```bash
rperf stat [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Also save profile to file (default: none) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `wall`) |
| `--report` | Include flat/cumulative profile tables in output |
| `--signal VALUE` | Timer signal (Linux only): signal number, or `false` for nanosleep thread |
| `--no-aggregate` | Disable sample aggregation (keep raw samples) |
| `--no-inherit` | Do not profile forked/spawned child processes (default: inherit) |
| `-v` | Print additional sampling statistics |

## rperf exec

[`rperf exec`](#index:rperf exec) runs a command with profiling and prints a full performance report to stderr — equivalent to `rperf stat --report`. It uses [wall](#index:wall mode) mode by default and does not save to a file.

```bash
rperf exec ruby my_app.rb
```

This prints everything `stat` shows (timing, time breakdown, GC/memory/OS stats) plus flat and cumulative top-50 function tables.

### exec options

```bash
rperf exec [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Also save profile to file (default: none) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `wall`) |
| `--signal VALUE` | Timer signal (Linux only): signal number, or `false` for nanosleep thread |
| `--no-aggregate` | Disable sample aggregation (keep raw samples) |
| `--no-inherit` | Do not profile forked/spawned child processes (default: inherit) |
| `-v` | Print additional sampling statistics |

## rperf record

[`rperf record`](#index:rperf record) profiles a command and saves the result to a file. This is the primary way to capture profiles for detailed analysis.

```bash
rperf record ruby my_app.rb
```

By default, it saves to `rperf.json.gz` in JSON format with CPU mode.

### Example: Recording a profile

```bash
rperf record ruby fib.rb
```

This creates `rperf.json.gz`. You can then analyze it with `rperf report` or convert to other formats.

### Choosing a profiling mode

rperf supports two profiling modes:

- **[cpu](#index:cpu mode)** (default): Measures per-thread CPU time. Best for finding functions that consume CPU cycles. Ignores time spent sleeping, in I/O, or waiting for the GVL.
- **[wall](#index:wall mode)**: Measures wall-clock time. Best for finding where wall time goes, including I/O, sleep, and GVL contention.

```bash
# CPU mode (default)
rperf record ruby my_app.rb

# Wall mode
rperf record -m wall ruby my_app.rb
```

### Choosing an output format

rperf auto-detects the format from the file extension:

```bash
# JSON format (default)
rperf record -o profile.json.gz ruby my_app.rb

# pprof format
rperf record -o profile.pb.gz ruby my_app.rb

# Collapsed stacks (for FlameGraph / speedscope)
rperf record -o profile.collapsed ruby my_app.rb

# Human-readable text
rperf record -o profile.txt ruby my_app.rb
```

You can also force the format explicitly:

```bash
rperf record --format text -o profile.dat ruby my_app.rb
```

### Example: Text output

```bash
rperf record -o profile.txt ruby fib.rb
```

The text output looks like this:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

 Flat:
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

### Example: Wall mode text output

```bash
rperf record -m wall -o wall_profile.txt ruby mixed.rb
```

```
Total: 311.8ms (wall)
Samples: 80, Frequency: 1000Hz

 Flat:
            44.1 ms  14.1%  Object#cpu_work (mixed.rb)
            13.9 ms   4.5%  Integer#times (<internal:numeric>)
             3.2 ms   1.0%  Kernel#sleep (<C method>)

 Cumulative:
           311.8 ms 100.0%  Integer#times (<internal:numeric>)
           311.8 ms 100.0%  block in <main> (mixed.rb)
           311.8 ms 100.0%  <main> (mixed.rb)
           253.8 ms  81.4%  Kernel#sleep (<C method>)
           253.8 ms  81.4%  Object#io_work (mixed.rb)
            58.0 ms  18.6%  Object#cpu_work (mixed.rb)

 Labels:
           250.6 ms  80.4%  %GVL: blocked
             0.0 ms   0.0%  %GVL: wait
```

In wall mode, the `%GVL: blocked` label accounts for the dominant cost — this is the sleep time in `io_work`. The CPU time for `cpu_work` is clearly separated. GVL and GC activity appear as labels on samples rather than as stack frames, and can be filtered with pprof's `-tagfocus` flag (e.g., `-tagfocus=%GVL=blocked`).

### Verbose output

The `-v` flag prints sampling statistics to stderr during profiling:

```bash
rperf record -v ruby my_app.rb
```

```
[Rperf] mode=cpu frequency=1000Hz
[Rperf] sampling: 98 calls, 0.11ms total, 1.1us/call avg
[Rperf] samples recorded: 904
[Rperf] top 10 by flat:
[Rperf]       53.4ms  50.1%  Object#cpu_work (-e)
[rperf]       17.0ms  15.9%  Integer#times (<internal:numeric>)
...
```

### record options

```bash
rperf record [options] command [args...]
```

| Option | Description |
|--------|-------------|
| `-o PATH` | Output file (default: `rperf.json.gz`) |
| `-f HZ` | Sampling frequency in Hz (default: 1000) |
| `-m MODE` | `cpu` or `wall` (default: `cpu`) |
| `--format FMT` | `json`, `pprof`, `collapsed`, or `text` (default: auto from extension) |
| `-p, --print` | Print text profile to stdout (same as `--format=text --output=/dev/stdout`) |
| `--signal VALUE` | Timer signal (Linux only): signal number, or `false` for nanosleep thread |
| `--no-aggregate` | Disable sample aggregation (keep raw samples) |
| `--no-inherit` | Do not profile forked/spawned child processes (default: inherit) |
| `-v` | Print sampling statistics to stderr |

## rperf report

[`rperf report`](#index:rperf report) opens a profile for analysis. For JSON (`.json.gz`) files, it opens the rperf viewer (no external tools required). For pprof (`.pb.gz`) files, it wraps `go tool pprof` and requires Go to be installed.

```bash
# Open rperf viewer (default, JSON format)
rperf report

# Open a specific file
rperf report profile.json.gz

# Open a pprof file (requires Go)
rperf report profile.pb.gz

# Print top functions
rperf report --top

# Print pprof text summary
rperf report --text

# Output static HTML viewer (no server needed)
rperf report --html profile.json.gz > report.html
```

The `--html` flag generates a single HTML file with the profile data embedded inline. It loads d3 and d3-flamegraph from CDN, so an internet connection is required to view the flamegraph — just open the file in a browser. This is useful for sharing profiles or hosting them on static sites like GitHub Pages.

### Example: Top and text output

Using the `fib.rb` profile recorded earlier:

```bash
rperf report --top rperf.json.gz
```

```
 Flat:
        577.3 ms 100.0%  Object#fib (fib.rb)
          0.0 ms   0.0%  <main> (-e)

 Cumulative:
        577.3 ms 100.0%  Object#fib (fib.rb)
        577.3 ms 100.0%  <main> (-e)
```

For `.pb.gz` files, `--top` and `--text` use `go tool pprof` and produce pprof-formatted output.

The default behavior (without `--top` or `--text`) opens the rperf viewer for JSON files, or an interactive web UI powered by [pprof](#cite:ren2010) for `.pb.gz` files.

### report options

| Option | Description |
|--------|-------------|
| `--top` | Print top functions by flat time |
| `--text` | Print pprof text summary |
| (default) | Open interactive web UI in browser |

## rperf diff

[`rperf diff`](#index:rperf diff) compares two pprof profiles, showing the difference (target - base). This is useful for measuring the impact of optimizations.

```bash
# Open diff in browser
rperf diff before.pb.gz after.pb.gz

# Print top functions by diff
rperf diff --top before.pb.gz after.pb.gz

# Print text diff
rperf diff --text before.pb.gz after.pb.gz
```

### Workflow example

```bash
# Profile the baseline
rperf record -o before.pb.gz ruby my_app.rb

# Make your optimization changes...

# Profile again
rperf record -o after.pb.gz ruby my_app.rb

# Compare
rperf diff before.pb.gz after.pb.gz
```

## Multi-process profiling

By default, all CLI subcommands (`stat`, `exec`, `record`) automatically profile [forked](#index:fork) and spawned Ruby child processes. Profiles from all processes are merged into a single output — the stat report shows aggregated data, and `record` produces a single merged file.

This is particularly useful for [preforking servers](#index:preforking server) like Unicorn and Puma, where the master process forks worker processes:

```bash
# Profile a Unicorn server with all its workers
rperf stat -m wall bundle exec unicorn -c config.rb

# Record a merged profile from a Puma server
rperf record -m wall -o profile.json.gz bundle exec puma
```

### How it works

When child process tracking is enabled (the default), rperf:

1. Sets up a session directory for collecting per-process profiles
2. Installs a `Process._fork` hook that restarts profiling in forked children
3. Spawned Ruby children (via `spawn`, `system`, backticks) inherit `RUBYOPT=-rrperf` and auto-start profiling
4. Each child writes its profile to the session directory on exit
5. The root process aggregates all profiles and produces the final output

Each child process's samples are tagged with a [`%pid`](#index:%pid label) label containing the process ID. This allows per-process filtering in the viewer (tagfocus by PID) or in pprof (`-tagfocus=%pid=1234`).

### Disabling child tracking

Use `--no-inherit` to profile only the root process:

```bash
rperf stat --no-inherit ruby my_app.rb
```

### Example: Fork with distinct work

```bash
rperf stat ruby -e '
  def parent_work = 10_000_000.times { 1 + 1 }
  def child_work  = 10_000_000.times { 1 + 1 }
  fork { child_work }
  Process.waitall
  parent_work
'
```

The stat output shows aggregated data from both processes, with a "Ruby processes profiled" count:

```
               2            [Rperf] Ruby processes profiled
```

### Limitations

- **Daemon children**: Processes that call `Process.daemon` and outlive the parent will have their profiles lost — the parent aggregates and cleans up the session directory at exit.
- **Cross-process snapshots**: `Rperf.snapshot` only covers the current process. There is no way to snapshot all children simultaneously.
- **Non-Ruby children**: Only Ruby child processes are profiled. Shell scripts, Python processes, etc. are not affected by rperf.
- **Independent rperf users**: Child processes that use rperf independently (`Rperf.start` in their own code) will conflict with the inherited auto-start session. Such programs should clear `RPERF_ENABLED` from their environment before requiring rperf.

## rperf help

`rperf help` prints the full reference documentation, including profiling modes, output formats, VM state labels, and diagnostic tips.

```bash
rperf help
```

This outputs detailed documentation suitable for both human reading and AI-assisted analysis.
