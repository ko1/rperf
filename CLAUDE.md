# rperf - Development Guide

## Project Overview

rperf is a safepoint-based sampling performance profiler for Ruby. It uses actual time deltas (not uniform sample counts) as weights to correct safepoint bias.

- Requires Ruby >= 3.4.0 (POSIX systems: Linux, macOS, etc.)
- Output: JSON (native, default), pprof protobuf, collapsed stacks, or text report

## Architecture

```
ext/rperf/rperf.c    -- C extension: timer (signal or thread), GVL/GC event hooks, sampling
lib/rperf.rb         -- Ruby API: start/stop, encoders (PProf, Collapsed, Text), stat output
lib/rperf/viewer.rb  -- Rack middleware: in-browser flamegraph viewer (d3-flame-graph)
lib/rperf/rack.rb    -- Rack middleware: per-request label annotation
exe/rperf            -- CLI: record, stat, exec, report, diff, help subcommands
test/                -- Unit tests (per-component: profiler, gvl, output, stat, cli, fork)
benchmark/           -- Accuracy benchmark suite (see benchmark/README.md)
```

## Build & Test

```bash
rake compile          # Build C extension (use CCACHE_DISABLE=1 if ccache fails)
rake test             # Run unit tests
```

## CLI Subcommands

```bash
rperf record [options] command [args...]   # Profile and save to file
rperf stat [options] command [args...]     # Profile and print summary to stderr
rperf exec [options] command [args...]     # Profile and print full report to stderr (stat --report)
rperf report [options] [file]              # Open pprof profile (requires Go)
rperf diff [options] base.pb.gz target.pb.gz  # Compare two profiles (requires Go)
rperf help                                 # Full reference documentation (AI-friendly)
```

## Benchmark

```bash
cd benchmark
rake compile          # Build benchmark workload C extension
ruby check_accuracy.rb                        # Default: rperf, mixed scenarios, cpu mode
ruby check_accuracy.rb -m wall                # Wall mode
ruby check_accuracy.rb -P stackprof -m cpu    # Compare with other profilers
ruby check_accuracy.rb -l -m wall             # Run under CPU load
```

See `benchmark/README.md` for full documentation.

## Key Design Decisions

- **Weight = time delta, not sample count**: Each sample's weight is `clock_now - clock_prev` in nanoseconds. This corrects for safepoint delays.
- **Current-thread-only sampling**: Timer-triggered postponed job samples only `rb_thread_current()` (the GVL holder). Combined with GVL event hooks, this gives complete thread coverage without iterating `Thread.list`.
- **GVL event tracking** (wall mode): Hooks SUSPENDED/READY/RESUMED thread events. SUSPENDED captures backtrace + normal sample. RESUMED records off-GVL time and GVL contention time as samples with `vm_state` (converted to `%GVL: blocked` / `%GVL: wait` labels at encode time), reusing the saved stack.
- **GC phase tracking**: Hooks GC_ENTER/GC_EXIT events. Records GC mark/sweep samples with `vm_state` (converted to `%GC: mark` / `%GC: sweep` labels at encode time), with wall time weight, attributed to the stack that triggered GC.
- **Deferred string resolution**: Sampling stores raw frame VALUEs in a pool (no synthetic frame VALUEs — GVL/GC state is tracked via `vm_state` enum, not frames). String resolution (`rb_profile_frame_full_label`, `rb_profile_frame_path`) happens at stop time, not during sampling. This keeps the hot path allocation-free.
- **No protobuf dependency**: pprof format is encoded with a hand-written encoder in `lib/rperf.rb` (`Rperf::PProf.encode`). String table is built in Ruby at encode time.
- **Multiple output formats**: JSON (rperf native, gzip JSON — default), pprof (gzip protobuf), collapsed stacks (FlameGraph/speedscope), text (human/AI-readable report). Format auto-detected from file extension. JSON preserves all internal data; `rperf report` opens it in the viewer without Go.
- **Timer implementation**: On Linux, defaults to `timer_create` + `SIGEV_THREAD_ID` targeting a dedicated worker thread (SIGRTMIN+8 by default). The worker thread receives timer signals and also performs sample aggregation. This gives precise interval timing (median ~1000us at 1000Hz) without interrupting Ruby threads. The signal number can be changed via `signal:` option. On non-Linux (macOS etc.) or with `signal: false`, falls back to a dedicated pthread + `nanosleep` loop (simpler but ~100us drift per tick).
- **Fork safety**: `pthread_atfork` child handler silently stops profiling in the child process. Clears timer/signal state, removes event hooks, and frees sample/frame buffers. The child can start a fresh profiling session; the parent continues unaffected.
- **Two clock modes**: cpu (`CLOCK_THREAD_CPUTIME_ID`) and wall (`CLOCK_MONOTONIC`).
- **Method-level profiling**: No line numbers. Frame labels use `rb_profile_frame_full_label` for qualified names (e.g., `Integer#times`).
- **Sample labels**: `Rperf.label(key: value)` attaches per-thread key-value labels to samples. Label sets are interned in Ruby (Hash → integer ID). C stores only the integer `label_set_id` per thread/sample — zero hot-path overhead beyond one integer copy. Labels are written into pprof `Sample.label` fields at encode time. The agg_table key includes `label_set_id` so same-stack different-label samples are kept separate. If profiling is not running, `label` is silently ignored (safe to call unconditionally, e.g., from Rack).
- **Deferred profiling**: `Rperf.start(defer: true)` starts profiler infrastructure but leaves the timer paused (`profile_refcount = 0`). `Rperf.profile(**labels) { block }` increments/decrements the refcount and arms/disarms the timer on 0↔1 transitions. Signal mode uses `timer_settime(zero)` to disarm; nanosleep mode uses `pthread_cond_wait` (infinite wait until signaled). On resume, all threads' `prev_time_ns` are reset to avoid inflated weights. `profile` also applies labels (like `label`), restored on block exit. Note: the timer is process-wide — while any thread's `profile` block is active, all threads are sampled. Each thread's samples carry its own labels, so they are distinguishable.

- **Viewer (Rack middleware)**: `Rperf::Viewer` is a Rack middleware that serves an in-browser profiling UI at `/rperf/` (configurable via `path:` option). Snapshots are stored in memory (up to `max_snapshots:`, default 24). The UI has three tabs: **Flamegraph** (d3-flame-graph), **Top** (flat/cumulative table, sortable by column click), **Tags** (label key/value breakdown with weight bars, click to filter). Filtering: **tagfocus** (regex on label values, Enter to apply), **tagignore** (dropdown checkboxes, includes `key = (none)` to exclude untagged samples), **tagroot/tagleaf** (dropdown checkboxes for label keys, prepend/append to stack). Logo SVG is loaded from `docs/logo.svg` at require time and inlined into the HTML. Tag keys are sorted (so `%`-prefixed VM state keys appear first).
- **RackMiddleware**: `Rperf::RackMiddleware` wraps requests with `Rperf.profile(endpoint: "GET /path")`, adding per-request labels and activating profiling for the duration of the request (works with `defer: true`).

## Coding Notes

- The C extension uses a single global `rperf_profiler_t`. Only one profiling session at a time.
- `Rperf.start` accepts `signal:` option (Linux only): `nil`/omitted = timer signal (default), `false`/`0` = nanosleep thread, positive integer = specific signal number (SIGKILL/SIGSTOP rejected). Frequency is validated: 1..10000 (10KHz max).
- C extension exports `_c_start`/`_c_stop`/`_c_snapshot`/`_c_set_label`/`_c_get_label`/`_c_set_label_sets`/`_c_get_label_sets`/`_c_profile_inc`/`_c_profile_dec`/`_c_running?`; Ruby wraps them as `Rperf.start`/`Rperf.stop`/`Rperf.snapshot`/`Rperf.label`/`Rperf.labels`/`Rperf.profile`.
- Frame pool (`VALUE *frame_pool`, initial ~1MB) stores raw frame VALUEs from `rb_profile_frames` (no synthetic frame VALUEs). A TypedData wrapper with `dmark` using `rb_gc_mark_locations` keeps them alive across GC. Frame table keys array grows dynamically (starts at 4096, 2x on demand) with atomic pointer swaps for GC dmark safety.
- `rb_profile_frames` writes directly into the frame pool (no intermediate buffer).
- Sample buffer and frame pool both grow by 2x on demand via `realloc`.
- Per-thread data (`rperf_thread_data_t`) is created via `rperf_thread_data_create()` and tracks per-thread timing state.
- Thread exit cleanup is handled by `RUBY_INTERNAL_THREAD_EVENT_EXITED` hook. Stop cleans up all live threads' thread-specific data.
- GVL blocked/wait samples (with `%GVL` labels) are only recorded in wall mode (CPU time doesn't advance while off-GVL). The C extension returns `vm_state` as a field in `rperf_agg_entry_t`; Ruby's `merge_vm_state_labels!` converts these to `%GVL` / `%GC` labels in `label_sets`. The agg key includes `vm_state` so same-stack different-state samples are kept separate.
- GC samples always use wall time regardless of mode.
- `stat` subcommand defaults to wall mode, outputs user/sys/real + time breakdown + GC stats. `--report` adds flat/cumulative top-50 tables. `record -p` prints text profile to stdout.
- `report` opens .json.gz files in the rperf viewer (no Go required) or falls back to `go tool pprof` for .pb.gz files. `diff` still requires Go.
- Benchmark workload methods (rw/cw/csleep/cwait) are numbered 1-1000 to appear as distinct functions in profiler output.

## Documentation

- `docs/help.md` — Source for `rperf help` CLI output. Also contains Ruby API reference.
- `docs/manual_src/` — Manual managed by ligarb. After editing, run `cd docs/manual_src && ligarb build` to regenerate `docs/manual/`.
- See `docs/manual_src/CLAUDE.md` for ligarb spec.

## Known Issues

- **`running_ec` race in Ruby VM**: `rb_postponed_job_trigger` from the timer thread may set the interrupt flag on the wrong thread's ec when a new thread's native thread starts before acquiring the GVL (`thread_pthread.c:2256` calls `ruby_thread_set_native` before `thread_sched_wait_running_turn`). This causes timer samples to miss threads doing C busy-wait, with their CPU time leaking into the next SUSPENDED event's stack. Tracked as a Ruby VM bug.
