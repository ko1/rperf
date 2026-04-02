# Load generator for the Rails example app
# Usage: ruby examples/rails/load.rb [base_url] [rounds]
#
# Sends concurrent requests to all endpoints, takes a snapshot after each round.

require "net/http"

base = ARGV[0] || "http://127.0.0.1:3000"
rounds = (ARGV[1] || 5).to_i
endpoints = %w[/cpu /cpu?n=36 /string /gc /slow /mixed /data]

puts "Target: #{base}"
puts "Rounds: #{rounds}, Endpoints: #{endpoints.size}, Concurrency: 6"
puts

rounds.times do |round|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  threads = 6.times.map do
    Thread.new do
      endpoints.each do |ep|
        Net::HTTP.get(URI("#{base}#{ep}"))
      end
    end
  end
  threads.each(&:join)

  # Take snapshot
  res = Net::HTTP.get(URI("#{base}/snapshot"))
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
  puts "Round #{round + 1}/#{rounds}: #{elapsed}s - #{res}"
end

puts
puts "Done! Visit #{base}/rperf/ to see the results."
