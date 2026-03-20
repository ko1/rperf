require "sperf"
require "sperf_workload_methods"

# Demonstrate postponed job flag race with multiple threads.
#
# Thread 1: cw10 x 25 + cwait10 x 5 (shuffled)
# Thread 2: cwait20 x 15 (keeps releasing/acquiring GVL)
#
# Expected: cw10 = 250ms, cwait10 ≈ 0ms (CPU mode)
# Actual:   some cw10 time leaks into cwait10 because:
#   1. Thread 1 finishes cw10, safepoint triggers thread switch
#   2. Thread 2 gets GVL, timer fires, flag set on Thread 2's ec
#   3. Thread 1 gets GVL back, runs next cw10, returns at safepoint
#   4. But flag is on Thread 2's ec → postponed job doesn't fire on Thread 1
#   5. Thread 1 continues to cwait10 → SUSPENDED captures cw10's weight

Sperf.start(frequency: 1000, mode: :cpu)

plan = ([[:cw, :cw10]] * 25 + [[:cwait, :cwait10]] * 5).shuffle(random: Random.new(1))

t1 = Thread.new do
  plan.each { |_, m| SperfWorkload.send(m, 10_000) }
end

t2 = Thread.new do
  15.times { SperfWorkload.cwait20(10_000) }
end

[t1, t2].each(&:join)
data = Sperf.stop

puts "samples: #{data[:samples].size}"
puts

data[:samples].each_with_index do |(frames, weight), i|
  leaf = frames[0][1]
  puts "%3d  %8.3fms  leaf=%s" % [i, weight / 1_000_000.0, leaf]
end

puts
puts "--- flat ---"
flat_w = Hash.new(0)
flat_n = Hash.new(0)
data[:samples].each do |frames, weight|
  flat_w[frames[0][1]] += weight
  flat_n[frames[0][1]] += 1
end
flat_w.sort_by { |_, w| -w }.each do |label, w|
  puts "  %8.1fms  %4d samples  %s" % [w / 1_000_000.0, flat_n[label], label]
end

total = data[:samples].sum { |_, w| w }
puts
puts "total: #{"%.1f" % (total / 1_000_000.0)}ms"
puts "expected: cw10=250ms, cwait10≈0ms, cwait20≈0ms"
puts "leaked to cwait10: #{"%.1f" % ((flat_w["SperfWorkload.cwait10"] || 0) / 1_000_000.0)}ms"
