# Ruby API

sperf provides a Ruby API for programmatic profiling. This is useful when you want to profile specific sections of code, integrate profiling into test suites, or build custom profiling workflows.

## Basic usage

### Block form (recommended)

The simplest way to use sperf is with the block form of [`Sperf.start`](#index:Sperf.start). It profiles the block and returns the profiling data:

```ruby
require "sperf"

data = Sperf.start(output: "profile.pb.gz", frequency: 1000, mode: :cpu) do
  # code to profile
end
```

When `output:` is specified, the profile is automatically written to the file when the block finishes. The method also returns the raw data hash for further processing.

### Example: Profiling a Fibonacci function

```ruby
require "sperf"

def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

data = Sperf.start(frequency: 1000, mode: :cpu) do
  fib(33)
end

Sperf.save("profile.txt", data)
```

Running this produces:

```
Total: 192.7ms (cpu)
Samples: 192, Frequency: 1000Hz

Flat:
     192.7ms 100.0%  Object#fib (example.rb)

Cumulative:
     192.7ms 100.0%  Object#fib (example.rb)
     192.7ms 100.0%  block in <main> (example.rb)
     192.7ms 100.0%  Sperf.start (lib/sperf.rb)
     192.7ms 100.0%  <main> (example.rb)
```

### Manual start/stop

For cases where block form is awkward, you can manually start and stop profiling:

```ruby
require "sperf"

Sperf.start(frequency: 1000, mode: :wall)

# ... code to profile ...

data = Sperf.stop
```

[`Sperf.stop`](#index:Sperf.stop) returns the data hash, or `nil` if the profiler was not running.

## Sperf.start parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `frequency:` | Integer | 1000 | Sampling frequency in Hz |
| `mode:` | Symbol | `:cpu` | `:cpu` or `:wall` |
| `output:` | String | `nil` | File path to write on stop |
| `verbose:` | Boolean | `false` | Print statistics to stderr |
| `format:` | Symbol | `nil` | `:pprof`, `:collapsed`, `:text`, or `nil` (auto-detect from output extension) |
| `signal:` | Integer/Boolean | `nil` | Linux only: `nil` = timer signal (default), `false` = nanosleep thread, positive integer = specific RT signal number |

## Sperf.stop return value

`Sperf.stop` returns `nil` if the profiler was not running. Otherwise it returns a Hash:

```ruby
{
  mode: :cpu,              # or :wall
  frequency: 1000,
  sampling_count: 1234,    # number of timer callbacks
  sampling_time_ns: 56789, # total time spent sampling (overhead)
  start_time_ns: 17740..., # CLOCK_REALTIME epoch nanos
  duration_ns: 10000000,   # profiling duration in nanos
  samples: [               # Array of [frames, weight, thread_seq]
    [frames, weight, seq], #   frames: [[path, label], ...] deepest-first
    ...                    #   weight: Integer (nanoseconds)
  ]                        #   seq: Integer (thread sequence, 1-based)
}
```

Each sample has:
- **frames**: An array of `[path, label]` pairs, ordered deepest-first (leaf frame at index 0)
- **weight**: Time in nanoseconds attributed to this sample
- **thread_seq**: Thread sequence number (1-based, assigned per profiling session)

## Sperf.save

[`Sperf.save`](#index:Sperf.save) writes profiling data to a file in any supported format:

```ruby
Sperf.save("profile.pb.gz", data)        # pprof format
Sperf.save("profile.collapsed", data)    # collapsed stacks
Sperf.save("profile.txt", data)          # text report
```

The format is auto-detected from the file extension. You can override it with the `format:` keyword:

```ruby
Sperf.save("output.dat", data, format: :text)
```

## Practical examples

### Profiling a web request handler

```ruby
require "sperf"

class ApplicationController
  def profile_action
    data = Sperf.start(mode: :wall) do
      # Simulate a typical request
      users = User.where(active: true).limit(100)
      result = users.map { |u| serialize_user(u) }
      render json: result
    end

    Sperf.save("request_profile.txt", data)
  end
end
```

Using wall mode here captures not just CPU time but also database I/O and any GVL contention.

### Comparing CPU and wall profiles

```ruby
require "sperf"

def workload
  # Mix of CPU and I/O
  100.times do
    compute_something
    sleep(0.001)
  end
end

# CPU profile: shows where CPU cycles go
cpu_data = Sperf.start(mode: :cpu) { workload }
Sperf.save("cpu.txt", cpu_data)

# Wall profile: shows where wall time goes
wall_data = Sperf.start(mode: :wall) { workload }
Sperf.save("wall.txt", wall_data)
```

The CPU profile will focus on `compute_something`, while the wall profile will show the `sleep` calls as `[GVL blocked]` time.

### Processing raw samples

You can work with the raw sample data programmatically:

```ruby
require "sperf"

data = Sperf.start(mode: :cpu) { workload }

# Find the hottest function
flat = Hash.new(0)
data[:samples].each do |frames, weight, thread_seq|
  leaf_label = frames.first&.last  # frames[0] is the leaf
  flat[leaf_label] += weight
end

top = flat.sort_by { |_, w| -w }.first(5)
top.each do |label, weight_ns|
  puts "#{label}: #{weight_ns / 1_000_000.0}ms"
end
```

### Generating collapsed stacks for FlameGraph

```ruby
require "sperf"

data = Sperf.start(mode: :cpu) { workload }
Sperf.save("profile.collapsed", data)
```

The collapsed format is one line per unique stack, compatible with Brendan Gregg's [FlameGraph](#cite:gregg2016) tools and speedscope:

```
frame1;frame2;...;leaf weight_ns
```

You can generate a flame graph SVG:

```bash
flamegraph.pl profile.collapsed > flamegraph.svg
```

Or open the `.collapsed` file directly in [speedscope](https://www.speedscope.app/).
