# Installation

## Installing the gem

sperf is distributed as a Ruby gem with a C extension:

```bash
gem install sperf
```

Or add it to your Gemfile:

```ruby
gem "sperf"
```

Then run:

```bash
bundle install
```

## Verifying the installation

Check that sperf is installed correctly:

```bash
sperf --help
```

You should see:

```
Usage: sperf record [options] command [args...]
       sperf stat [options] command [args...]
       sperf report [options] [file]
       sperf diff [options] base.pb.gz target.pb.gz
       sperf help

Run 'sperf help' for full documentation
```

## Platform support

sperf supports POSIX systems:

| Platform | Timer implementation | Notes |
|----------|---------------------|-------|
| Linux | `timer_create` + signal (default) | Best precision (~1000us at 1000Hz) |
| Linux | `nanosleep` thread (with `signal: false`) | Fallback, ~100us drift/tick |
| macOS | `nanosleep` thread | Signal-based timer not available |

On Linux, sperf uses `timer_create` with `SIGEV_SIGNAL` and a `sigaction` handler by default. This provides precise interval timing with no extra thread. The signal number defaults to `SIGRTMIN+8` and can be changed via the `signal:` option.

On macOS (and when `signal: false` is set on Linux), sperf falls back to a dedicated pthread with a `nanosleep` loop.

## Optional: Go toolchain

The `sperf report` and `sperf diff` subcommands are thin wrappers around `go tool pprof`. If you want to use these commands, install Go from [go.dev](https://go.dev/dl/).

Without Go, you can still use all other sperf features. You can view pprof files with other tools like [speedscope](https://www.speedscope.app/) or generate text/collapsed output directly.
