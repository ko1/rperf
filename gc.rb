# GC tracking demo
#
# Run: ruby -Ilib gc.rb
#
# Creates garbage in different methods to see which code triggers GC.
# Expected: [GC marking] samples attributed to the allocating methods.

require "sperf"

def alloc_strings(n)
  n.times { "hello" * 50 }
end

def alloc_arrays(n)
  n.times.map { [1, 2, 3, 4, 5] * 1000 }
end

def alloc_hashes(n)
  n.times { { a: 1, b: 2, c: 3, d: 4, e: 5 } }
end

data = Sperf.start(frequency: 1000, mode: :wall, verbose: true, output: 'sperf.data') do
  5.times do
    alloc_strings(200_000)
    alloc_arrays(200_000)
    alloc_hashes(200_000)
  end
end

# Categorize
gc_marking = []
gc_sweeping = []
normal = []

data[:samples].each do |frames, weight|
  labels = frames.map { |_, l| l }
  if labels.include?("[GC marking]")
    gc_marking << [frames, weight]
  elsif labels.include?("[GC sweeping]")
    gc_sweeping << [frames, weight]
  else
    normal << [frames, weight]
  end
end

total = (normal + gc_marking + gc_sweeping).sum { |_, w| w }

puts
puts "--- Summary ---"
puts "Normal:        #{normal.size} samples, #{"%.1f" % (normal.sum { |_, w| w } / 1_000_000.0)}ms"
puts "[GC marking]:  #{gc_marking.size} samples, #{"%.1f" % (gc_marking.sum { |_, w| w } / 1_000_000.0)}ms"
puts "[GC sweeping]: #{gc_sweeping.size} samples, #{"%.1f" % (gc_sweeping.sum { |_, w| w } / 1_000_000.0)}ms"

puts
puts "--- Top by flat (leaf) ---"
flat = Hash.new(0)
data[:samples].each do |frames, weight|
  flat[frames[0][1]] += weight
end
flat.sort_by { |_, w| -w }.first(10).each do |label, w|
  pct = total > 0 ? w * 100.0 / total : 0
  puts "  #{"%.1f" % (w / 1_000_000.0)}ms  #{"%.1f" % pct}%  #{label}"
end

puts
puts "--- [GC marking] by triggering method ---"
by_method = Hash.new(0)
gc_marking.each do |frames, weight|
  # frames[0] = [GC marking], frames[1] = method that triggered GC
  method_label = frames[1] ? frames[1][1] : "?"
  by_method[method_label] += weight
end
by_method.sort_by { |_, w| -w }.each do |label, w|
  puts "  #{"%.1f" % (w / 1_000_000.0)}ms  #{label}"
end

if gc_sweeping.size > 0
  puts
  puts "--- [GC sweeping] by triggering method ---"
  by_method_s = Hash.new(0)
  gc_sweeping.each do |frames, weight|
    method_label = frames[1] ? frames[1][1] : "?"
    by_method_s[method_label] += weight
  end
  by_method_s.sort_by { |_, w| -w }.each do |label, w|
    puts "  #{"%.1f" % (w / 1_000_000.0)}ms  #{label}"
  end
end