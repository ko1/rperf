# Output Formats

sperf supports three output formats. The format is auto-detected from the file extension, or can be set explicitly with the `--format` flag (CLI) or `format:` parameter (API).

## pprof (default)

The pprof format is a gzip-compressed Protocol Buffers binary. This is the standard format used by Go's pprof tooling and is the default output of sperf.

**Extension convention**: `.pb.gz`

**How to view**:

```bash
# Interactive web UI (requires Go)
sperf report profile.pb.gz

# Top functions
sperf report --top profile.pb.gz

# Text report
sperf report --text profile.pb.gz

# Or use go tool pprof directly
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
go tool pprof -flame profile.pb.gz
```

You can also import pprof files into [speedscope](https://www.speedscope.app/) via its web interface.

**Advantages**: Standard format supported by a wide ecosystem of tools. Supports diff comparison between two profiles. Interactive exploration with flame graphs, call graphs, and source annotations.

## Collapsed stacks

The collapsed stacks format is a plain text format with one line per unique stack trace. Each line contains a semicolon-separated stack (bottom-to-top) followed by a space and the weight in nanoseconds.

**Extension convention**: `.collapsed`

**Format**:

```
bottom_frame;...;top_frame weight_ns
```

**Example output**:

```
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times;Object#cpu_work 53419170
<main>;Integer#times;block in <main>;Object#cpu_work;Integer#times 16962309
<main>;Integer#times;block in <main>;Object#io_work;Kernel#sleep 2335151
```

**How to use**:

```bash
# Generate a FlameGraph SVG
sperf record -o profile.collapsed ruby my_app.rb
flamegraph.pl profile.collapsed > flamegraph.svg

# Open in speedscope (drag-and-drop the file)
open https://www.speedscope.app/
```

**Advantages**: Simple text format, easy to process with command-line tools. Compatible with Brendan Gregg's [FlameGraph](#cite:gregg2016) tools and speedscope.

### Parsing collapsed stacks programmatically

```ruby
File.readlines("profile.collapsed").each do |line|
  stack, weight = line.rpartition(" ").then { |s, _, w| [s, w.to_i] }
  frames = stack.split(";")
  # frames[0] is bottom (main), frames[-1] is leaf (hot)
  puts "#{frames.last}: #{weight / 1_000_000.0}ms"
end
```

## Text report

The text format is a human-readable (and AI-readable) report showing flat and cumulative top-N tables.

**Extension convention**: `.txt`

**Example output**:

```
Total: 509.5ms (cpu)
Samples: 509, Frequency: 1000Hz

Flat:
     509.5ms 100.0%  Object#fib (fib.rb)

Cumulative:
     509.5ms 100.0%  Object#fib (fib.rb)
     509.5ms 100.0%  <main> (fib.rb)
```

**Sections**:

- **Header**: Total profiled time, sample count, and frequency
- **Flat table**: Functions sorted by self time (the function was the leaf/deepest frame)
- **Cumulative table**: Functions sorted by total time (the function appeared anywhere in the stack)

**Advantages**: No tooling required — readable with `cat`. Top 50 entries per table by default. Good for quick analysis, sharing in issue reports, or feeding to AI assistants.

## Format comparison

| Feature | pprof | collapsed | text |
|---------|-------|-----------|------|
| File size | Small (binary + gzip) | Medium (text) | Small (text) |
| Flame graph | Yes (via pprof web UI) | Yes (via flamegraph.pl) | No |
| Call graph | Yes | No | No |
| Diff comparison | Yes (`sperf diff`) | No | No |
| No tools needed | No (requires Go) | No (requires flamegraph.pl) | Yes |
| Programmatic parsing | Complex (protobuf) | Simple | Simple |
| AI-friendly | No | Yes | Yes |

## Auto-detection rules

| File extension | Format |
|----------------|--------|
| `.collapsed` | Collapsed stacks |
| `.txt` | Text report |
| Anything else | pprof |

The default output file (`sperf.data`) uses pprof format.
