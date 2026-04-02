# I/O + thread workload: file I/O, sleep, thread contention
# Expected: ~3s wall time, low CPU time. Best profiled with -m wall.

require "tempfile"
require "digest"

def file_io_work
  Tempfile.create("rperf_example") do |f|
    # Write 10MB
    100.times { f.write("x" * 100_000) }
    f.rewind
    # Read and hash
    Digest::SHA256.hexdigest(f.read)
  end
end

def thread_contention
  shared = []
  mutex = Mutex.new

  threads = 4.times.map do |id|
    Thread.new do
      500_000.times do |i|
        mutex.synchronize { shared << i }
      end
    end
  end
  threads.each(&:join)
  shared.size
end

def sleep_work
  # Simulate network latency
  10.times do
    sleep 0.1
    # Small CPU burst between sleeps
    sum = 0
    100_000.times { |i| sum += i }
  end
end

puts "File I/O (write 10MB + SHA256)..."
hash = file_io_work
puts "SHA256: #{hash[0, 16]}..."

puts "Thread contention (4 threads, shared mutex)..."
count = thread_contention
puts "Total items: #{count}"

puts "Simulated network latency (5 x 100ms sleep)..."
sleep_work
puts "Done"
