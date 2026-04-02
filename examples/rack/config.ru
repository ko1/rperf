require_relative "../../lib/rperf"
require_relative "../../lib/rperf/viewer"
require_relative "../../lib/rperf/rack"

# --- Workload helpers ---

def cpu_work(n = 1_000_000)
  sum = 0
  n.times { |i| sum += i * i }
  sum
end

def io_work
  require "tempfile"
  Tempfile.create("rperf_rack") do |f|
    f.write("x" * 500_000)
    f.rewind
    f.read.size
  end
end

def gc_work
  10.times { Array.new(100_000) { { a: rand, b: rand.to_s } } }
end

def sleep_work
  sleep 0.05
  cpu_work(200_000)
end

# --- Rack app ---

app = proc do |env|
  body = case env["PATH_INFO"]
  when "/cpu"
    "sum = #{cpu_work}"
  when "/io"
    "read #{io_work} bytes"
  when "/gc"
    gc_work
    "gc work done"
  when "/sleep"
    sleep_work
    "sleep + cpu done"
  when "/mixed"
    cpu_work(500_000)
    io_work
    sleep 0.02
    gc_work
    "mixed done"
  when "/snapshot"
    entry = Rperf::Viewer.instance&.take_snapshot!
    entry ? "Snapshot ##{entry[:id]} taken (#{entry[:data][:sampling_count]} samples)" : "Profiler not running"
  else
    <<~TEXT
      rperf Rack Example
      ==================
      GET /cpu      - CPU-bound work
      GET /io       - File I/O work
      GET /gc       - GC-heavy work
      GET /sleep    - Sleep + CPU work
      GET /mixed    - All of the above
      GET /snapshot - Take a profiler snapshot
      GET /rperf/   - Profiler viewer UI
    TEXT
  end

  [200, { "content-type" => "text/plain" }, [body + "\n"]]
end

# --- Start profiling ---

Rperf.start(mode: :wall, frequency: 999, defer: true)

use Rperf::Viewer, max_snapshots: 50
use Rperf::RackMiddleware
run app

# --- Auto-load: generate traffic and take snapshots ---

Thread.new do
  require "net/http"
  sleep 1

  base = URI("http://127.0.0.1:9292")
  endpoints = %w[/cpu /io /gc /sleep /mixed]

  3.times do |round|
    threads = 4.times.map do
      Thread.new do
        6.times do
          ep = endpoints.sample
          Net::HTTP.get(URI("#{base}#{ep}"))
        end
      end
    end
    threads.each(&:join)
    Net::HTTP.get(URI("#{base}/snapshot"))
    $stderr.puts "[rperf] snapshot ##{round + 1} taken"
  end

  $stderr.puts "[rperf] Ready! Visit http://127.0.0.1:9292/rperf/"
end
