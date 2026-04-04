# Output Formats

rperf supports four output formats. The format is auto-detected from the file extension, or can be set explicitly with the `--format` flag (CLI) or `format:` parameter (API).

## JSON (default)

The [JSON](#index:json) format is rperf's native format and the default output. It comes in two variants:

- **`.json.gz`** (default) — gzip-compressed JSON. Compact, recommended for storage and sharing.
- **`.json`** — plain text JSON. Readable by `jq`, text editors, and any JSON tool without decompression.

Both variants are auto-detected by `Rperf.load` and `rperf report`.

**How to view**:

```bash
# Open rperf viewer
rperf report profile.json.gz
rperf report profile.json      # also works
```

**How to load in Ruby**:

```ruby
data = Rperf.load("profile.json.gz")  # gzip
data = Rperf.load("profile.json")     # plain text
```

**Advantages**: Native rperf format, no external tools required to view. Portable format. Can be loaded back into Ruby or processed by any JSON-capable tool. Use `.json` when you want to inspect or pipe through `jq`.

## pprof

The [pprof](#index:pprof) format is a gzip-compressed Protocol Buffers binary. This is the standard format used by Go's pprof tooling.

**Extension convention**: `.pb.gz`

**How to view**:

```bash
# Interactive web UI (requires Go)
rperf report profile.pb.gz

# Top functions
rperf report --top profile.pb.gz

# Text report
rperf report --text profile.pb.gz

# Or use go tool pprof directly
go tool pprof -http=:8080 profile.pb.gz
go tool pprof -top profile.pb.gz
```

You can also import pprof files into [speedscope](https://www.speedscope.app/) via its web interface.

**Advantages**: Standard format supported by a wide ecosystem of tools. Supports diff comparison between two profiles. Interactive exploration with flame graphs, call graphs, and source annotations.

### Embedded metadata

rperf embeds the following metadata in each pprof profile:

| Field | Description |
|-------|-------------|
| `comment` | rperf version, profiling mode, frequency, Ruby version |
| `time_nanos` | Profile collection start time (epoch nanoseconds) |
| `duration_nanos` | Profile duration (nanoseconds) |
| `doc_url` | Link to rperf documentation |

View comments with: `go tool pprof -comments profile.pb.gz`

### Sample labels

Each sample carries a `thread_seq` numeric label — a thread sequence number (1-based) assigned when rperf first sees each thread during a profiling session. When [`Rperf.label`](#index:Rperf.label) is used, custom key-value string labels are also attached to samples.

These labels can be filtered with `go tool pprof`:

```bash
go tool pprof -tagroot=thread_seq profile.pb.gz     # group by thread
go tool pprof -tagfocus=request=abc-123 profile.pb.gz  # filter by label
go tool pprof -tagroot=request profile.pb.gz         # group by label
```

> [!NOTE]
> The rperf viewer (JSON format) supports the same tag operations — tagfocus, tagignore, tagroot, tagleaf — without requiring Go. See [In-browser viewer](#index:Rperf::Viewer) for details.

## Collapsed stacks

The [collapsed stacks](#index:collapsed stacks) format is a plain text format with one line per unique stack trace. Each line contains a semicolon-separated stack (bottom-to-top) followed by a space and the weight in nanoseconds.

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
rperf record -o profile.collapsed ruby my_app.rb
flamegraph.pl profile.collapsed > flamegraph.svg

# Open in speedscope (drag-and-drop the .collapsed file)
# macOS: open https://www.speedscope.app/
# Linux: xdg-open https://www.speedscope.app/
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
           509.5 ms 100.0%  Object#fib (fib.rb)

 Cumulative:
           509.5 ms 100.0%  Object#fib (fib.rb)
           509.5 ms 100.0%  <main> (fib.rb)
```

**Sections**:

- **Header**: Total profiled time, sample count, and frequency
- **Flat table**: Functions sorted by self time (the function was the leaf/deepest frame)
- **Cumulative table**: Functions sorted by total time (the function appeared anywhere in the stack)

**Advantages**: No tooling required — readable with `cat`. Top 50 entries per table by default. Good for quick analysis, sharing in issue reports, or feeding to AI assistants.

## Format comparison

| Feature | json | pprof | collapsed | text |
|---------|------|-------|-----------|------|
| File size | Medium (json + gzip) | Small (binary + gzip) | Medium (text) | Small (text) |
| Flame graph | Yes (via rperf viewer) | Yes (via pprof web UI) | Yes (via flamegraph.pl) | No |
| Call graph | No | Yes | No | No |
| Diff comparison | Yes (`rperf diff`, requires Go) | Yes (`rperf diff`) | No | No |
| No tools needed | Yes | No (requires Go) | No (requires flamegraph.pl) | Yes |
| Load back into Ruby | Yes (`Rperf.load`) | No | No | No |
| Programmatic parsing | Easy (JSON) | Complex (protobuf) | Simple | Simple |
| AI-friendly | Yes | No | Yes | Yes |

## Auto-detection rules

| File extension | Format |
|----------------|--------|
| `.json.gz` | JSON (default) |
| `.pb.gz` | pprof |
| `.collapsed` | Collapsed stacks |
| `.txt` | Text report |

The default output file (`rperf.json.gz`) uses JSON format.
