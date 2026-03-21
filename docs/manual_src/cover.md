# sperf guide

A safepoint-based sampling performance profiler for Ruby.

sperf profiles your Ruby programs by sampling at safepoints and using actual time deltas as weights to correct safepoint bias. It provides a `perf`-like CLI, a Ruby API, and outputs standard pprof format.

**Key features:**

- CPU and wall-clock profiling modes
- Time-weighted sampling that corrects safepoint bias
- GVL contention and GC phase tracking
- pprof, collapsed stacks, and text output formats
- Low overhead (< 0.2% at default 1000 Hz)
- Requires Ruby >= 3.4.0 on POSIX systems (Linux, macOS)
