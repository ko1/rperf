# GVL event tracking demo script
#
# Uses benchmark workloads with mixed cw/cwait/csleep across 5 threads.
# Run: ruby -Ilib -Ibenchmark/lib test.rb
#
# Workloads (n_usec = microseconds):
#   cw(n)     — C busy-wait, holds GVL, consumes CPU
#   csleep(n) — nanosleep with GVL held, no CPU consumed
#   cwait(n)  — nanosleep with GVL released, no CPU consumed

require "sperf"
require "sperf_workload_methods"

# Each call is 10ms (10_000 usec). 100 calls total, split across 5 threads.
# Shuffle order within each thread for variety.
USEC = 10_000

thread_plans = [
  # Thread 1: heavy CPU — 25 cw, 5 cwait
  ([[:cw, :cw10]] * 25 + [[:cwait, :cwait10]] * 5).shuffle(random: Random.new(1)),
  # Thread 2: heavy off-GVL — 5 cw, 20 cwait, 5 csleep
  ([[:cw, :cw20]] * 5 + [[:cwait, :cwait20]] * 20 + [[:csleep, :csleep20]] * 5).shuffle(random: Random.new(2)),
  # Thread 3: mixed — 10 cw, 10 cwait, 5 csleep
  ([[:cw, :cw30]] * 10 + [[:cwait, :cwait30]] * 10 + [[:csleep, :csleep30]] * 5).shuffle(random: Random.new(3)),
  # Thread 4: mostly sleep — 2 cw, 3 cwait, 10 csleep
  ([[:cw, :cw40]] * 2 + [[:cwait, :cwait40]] * 3 + [[:csleep, :csleep40]] * 10).shuffle(random: Random.new(4)),
  # Thread 5: all off-GVL — 15 cwait
  ([[:cwait, :cwait50]] * 15).shuffle(random: Random.new(5)),
]

# Compute expected times per method
def compute_expected(plans, usec)
  cpu_ms = Hash.new(0.0)
  wall_ms = Hash.new(0.0)
  gvl_blocked_ms = Hash.new(0.0)

  plans.each do |plan|
    plan.each do |type, method_name|
      ms = usec / 1000.0
      name = "SperfWorkload.#{method_name}"
      case type
      when :cw
        cpu_ms[name] += ms
        wall_ms[name] += ms
      when :csleep
        # holds GVL, no CPU, but wall time passes
        wall_ms[name] += ms
      when :cwait
        # releases GVL, no CPU, wall time as [GVL blocked]
        wall_ms[name] += ms   # appears as cum (including blocked child)
        gvl_blocked_ms[name] += ms
      end
    end
  end
  { cpu: cpu_ms, wall: wall_ms, gvl_blocked: gvl_blocked_ms }
end

expected = compute_expected(thread_plans, USEC)

def run_scenario(thread_plans, usec, mode)
  Sperf.start(frequency: 1000, mode: mode, verbose: true)

  threads = thread_plans.map do |plan|
    Thread.new do
      plan.each do |_type, method_name|
        SperfWorkload.send(method_name, usec)
      end
    end
  end
  threads.each(&:join)

  Sperf.stop
end

def print_results(data, expected_flat, expected_blocked, label)
  gvl_blocked = []
  gvl_wait = []
  normal = []

  data[:samples].each do |frames, weight|
    labels = frames.map { |_, l| l }
    if labels.include?("[GVL blocked]")
      gvl_blocked << [frames, weight]
    elsif labels.include?("[GVL wait]")
      gvl_wait << [frames, weight]
    else
      normal << [frames, weight]
    end
  end

  total_all = (normal + gvl_blocked + gvl_wait).sum { |_, w| w }

  puts "--- Sample counts ---"
  puts "Normal:        #{normal.size}"
  puts "[GVL blocked]: #{gvl_blocked.size}"
  puts "[GVL wait]:    #{gvl_wait.size}"

  puts
  puts "--- Total weights ---"
  puts "Normal:        #{"%.1f" % (normal.sum { |_, w| w } / 1_000_000.0)}ms"
  puts "[GVL blocked]: #{"%.1f" % (gvl_blocked.sum { |_, w| w } / 1_000_000.0)}ms"
  puts "[GVL wait]:    #{"%.1f" % (gvl_wait.sum { |_, w| w } / 1_000_000.0)}ms"
  puts "Total:         #{"%.1f" % (total_all / 1_000_000.0)}ms"

  # Flat top
  puts
  puts "--- Top by flat (leaf) ---"
  puts "  %10s %10s  %s" % ["actual", "expected", "method"]
  flat = Hash.new(0)
  data[:samples].each do |frames, weight|
    leaf = frames[0] ? frames[0][1] : "?"
    flat[leaf] += weight
  end
  flat.sort_by { |_, w| -w }.first(15).each do |name, w|
    exp = expected_flat[name]
    exp_str = exp && exp > 0 ? "#{"%.1f" % exp}ms" : ""
    puts "  %10s %10s  %s" % ["#{"%.1f" % (w / 1_000_000.0)}ms", exp_str, name]
  end

  # [GVL blocked] breakdown
  if gvl_blocked.size > 0 && expected_blocked
    puts
    puts "--- [GVL blocked] by method ---"
    puts "  %10s %10s  %s" % ["actual", "expected", "method"]
    blocked_by = Hash.new(0)
    gvl_blocked.each do |frames, weight|
      method_label = frames[1] ? frames[1][1] : "?"
      blocked_by[method_label] += weight
    end
    blocked_by.sort_by { |_, w| -w }.each do |name, w|
      exp = expected_blocked[name]
      exp_str = exp && exp > 0 ? "#{"%.1f" % exp}ms" : ""
      puts "  %10s %10s  %s" % ["#{"%.1f" % (w / 1_000_000.0)}ms", exp_str, name]
    end
  end

  # [GVL wait] breakdown
  if gvl_wait.size > 0
    puts
    puts "--- [GVL wait] by method ---"
    wait_by = Hash.new(0)
    gvl_wait.each do |frames, weight|
      method_label = frames[1] ? frames[1][1] : "?"
      wait_by[method_label] += weight
    end
    wait_by.sort_by { |_, w| -w }.each do |name, w|
      puts "  #{"%.1f" % (w / 1_000_000.0)}ms  #{name}"
    end
  end

  # Cum top
  puts
  puts "--- Top by cum ---"
  puts "  %10s  %s" % ["actual", "method"]
  cum = Hash.new(0)
  data[:samples].each do |frames, weight|
    seen = {}
    frames.each do |_, l|
      unless seen[l]
        cum[l] += weight
        seen[l] = true
      end
    end
  end
  cum.sort_by { |_, w| -w }.first(15).each do |name, w|
    puts "  %10s  %s" % ["#{"%.1f" % (w / 1_000_000.0)}ms", name]
  end
end

# --- Expected summary ---
puts "=" * 60
puts "  EXPECTED (per method, #{USEC/1000}ms per call)"
puts "=" * 60
puts
puts "  %-30s %8s %8s %8s" % ["method", "cpu", "wall", "blocked"]
all_methods = (expected[:cpu].keys + expected[:wall].keys + expected[:gvl_blocked].keys).uniq.sort
all_methods.each do |m|
  c = expected[:cpu][m]
  w = expected[:wall][m]
  b = expected[:gvl_blocked][m]
  puts "  %-30s %7.0fms %7.0fms %7.0fms" % [m, c, w, b]
end
total_cpu = expected[:cpu].values.sum
total_wall = expected[:wall].values.sum
total_blocked = expected[:gvl_blocked].values.sum
puts "  %-30s %7.0fms %7.0fms %7.0fms" % ["TOTAL", total_cpu, total_wall, total_blocked]

# --- Wall mode ---
puts
puts "=" * 60
puts "  WALL MODE"
puts "=" * 60
puts
data_wall = run_scenario(thread_plans, USEC, :wall)
print_results(data_wall, expected[:wall], expected[:gvl_blocked], "wall")

# --- CPU mode ---
puts
puts "=" * 60
puts "  CPU MODE"
puts "=" * 60
puts
data_cpu = run_scenario(thread_plans, USEC, :cpu)
print_results(data_cpu, expected[:cpu], nil, "cpu")

# Save pprof files
dir = "/tmp/claude-1000/sperf-demo"
Dir.mkdir(dir) unless Dir.exist?(dir)

[[:wall, data_wall], [:cpu, data_cpu]].each do |mode, data|
  path = File.join(dir, "#{mode}.pb.gz")
  encoded = Sperf::PProf.encode(data)
  File.binwrite(path, Sperf.gzip(encoded))
  puts
  puts "Saved #{mode} profile: #{path}"
  puts "  go tool pprof -http=:8080 #{path}"
end
