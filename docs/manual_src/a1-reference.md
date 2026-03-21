# Quick Reference

## CLI cheat sheet

```bash
# Quick performance overview
sperf stat ruby my_app.rb

# Record to default file (sperf.data, pprof format, cpu mode)
sperf record ruby my_app.rb

# Record with options
sperf record -m wall -f 500 -o profile.pb.gz ruby my_app.rb

# Record to text format
sperf record -o profile.txt ruby my_app.rb

# Record to collapsed stacks
sperf record -o profile.collapsed ruby my_app.rb

# View profile in browser (requires Go)
sperf report

# Print top functions
sperf report --top profile.pb.gz

# Compare two profiles
sperf diff before.pb.gz after.pb.gz

# Full documentation
sperf help
```

## Ruby API cheat sheet

```ruby
require "sperf"

# Block form
data = Sperf.start(output: "profile.pb.gz", mode: :cpu) do
  # code to profile
end

# Manual form
Sperf.start(frequency: 1000, mode: :wall)
# ...
data = Sperf.stop

# Save to file
Sperf.save("profile.pb.gz", data)
Sperf.save("profile.collapsed", data)
Sperf.save("profile.txt", data)
```

## Environment variables

These are used internally by the CLI to configure the auto-started profiler:

| Variable | Values | Description |
|----------|--------|-------------|
| `SPERF_ENABLED` | `1` | Enable auto-start on require |
| `SPERF_OUTPUT` | path | Output file path |
| `SPERF_FREQUENCY` | integer | Sampling frequency in Hz |
| `SPERF_MODE` | `cpu`, `wall` | Profiling mode |
| `SPERF_FORMAT` | `pprof`, `collapsed`, `text` | Output format |
| `SPERF_VERBOSE` | `1` | Print statistics to stderr |

## Profiling mode comparison

| Aspect | cpu | wall |
|--------|-----|------|
| Clock | `CLOCK_THREAD_CPUTIME_ID` | `CLOCK_MONOTONIC` |
| I/O time | Not measured | `[GVL blocked]` |
| Sleep time | Not measured | `[GVL blocked]` |
| GVL contention | Not measured | `[GVL wait]` |
| GC time | `[GC marking]`, `[GC sweeping]` | `[GC marking]`, `[GC sweeping]` |
| Best for | CPU hotspots | Latency analysis |

## Output format comparison

| Extension | Format | Tooling required |
|-----------|--------|-----------------|
| `.pb.gz` (default) | pprof protobuf | Go (`sperf report`) |
| `.collapsed` | Collapsed stacks | flamegraph.pl or speedscope |
| `.txt` | Text report | None |

## Synthetic frames

| Frame | Mode | Meaning |
|-------|------|---------|
| `[GVL blocked]` | wall | Thread off-GVL (I/O, sleep, C ext) |
| `[GVL wait]` | wall | Thread waiting for GVL (contention) |
| `[GC marking]` | both | GC marking phase (wall time) |
| `[GC sweeping]` | both | GC sweeping phase (wall time) |
