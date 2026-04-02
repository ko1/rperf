# GC-heavy workload: lots of short-lived object allocation
# Expected: ~3s, significant GC time visible in wall mode (%GC labels)

def allocate_strings(n)
  n.times.map { |i| "string_#{i}_#{"x" * (i % 100)}" }
end

def build_nested_hashes(depth, breadth)
  return { value: rand } if depth == 0
  breadth.times.each_with_object({}) do |i, h|
    h["key_#{i}"] = build_nested_hashes(depth - 1, breadth)
  end
end

def churn_objects(rounds)
  rounds.times do
    # Create and discard arrays of small objects
    ary = Array.new(50_000) { { a: rand, b: rand.to_s, c: [1, 2, 3] } }
    ary.select { |h| h[:a] > 0.5 }.map { |h| h[:b].upcase }
  end
end

GC.start # clean slate

puts "Allocating 2,000,000 strings..."
strings = allocate_strings(2_000_000)
puts "Allocated #{strings.size} strings (forcing GC...)"
strings = nil
GC.start

puts "Building nested hash trees (depth=6, breadth=6)..."
tree = build_nested_hashes(6, 6)
puts "Tree has #{tree.size} top-level keys (forcing GC...)"
tree = nil
GC.start

puts "Object churn (40 rounds x 50k hashes)..."
churn_objects(40)
puts "Done"
