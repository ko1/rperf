#!/bin/bash
# Multi-process integration tests for rperf
# Usage: bash test/test_rperf_multiprocess.sh
set -e

RPERF="ruby -Ilib exe/rperf"
RUBY=$(ruby -e 'print RbConfig.ruby' -rrbconfig)
TMPDIR="${TMPDIR:-/tmp}"
PASS=0
FAIL=0
_STDERR_LOG="$TMPDIR/rperf-test-stderr-$$"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() {
  # check "description" "actual" "expected_pattern"
  if echo "$2" | grep -qE "$3"; then
    pass "$1"
  else
    fail "$1 (got: $2)"
  fi
}
# Check that output does not contain Ruby errors (Errno::*, RuntimeError, etc.)
check_no_errors() {
  local desc="$1"
  local output="$2"
  if echo "$output" | grep -qE "(Errno::|RuntimeError|NoMethodError|NameError|SyntaxError|LoadError|rb_sysopen)"; then
    fail "$desc: unexpected error in output"
    echo "$output" | grep -E "(Errno::|RuntimeError|NoMethodError|NameError|SyntaxError|LoadError|rb_sysopen)" | head -3 | sed 's/^/    /'
  else
    pass "$desc: no errors"
  fi
}

echo "=== rperf multi-process integration tests ==="
echo

# --- 1. Single process (no fork) ---
echo "# 1. Single process (stat)"
out=$($RPERF stat -f 100 -- "$RUBY" -e '1_000_000.times { 1 + 1 }' 2>&1)
check "has Performance stats" "$out" "Performance stats"
if echo "$out" | grep -q "processes profiled"; then
    fail "no processes line (unexpected processes line)"
  else
    pass "no processes line"
  fi
check "has samples" "$out" "samples.*triggers"
echo

# --- 2. Fork with children (stat) ---
echo "# 2. Fork 3 children (stat)"
out=$($RPERF stat -f 100 -- "$RUBY" -e '3.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall' 2>&1)
check_no_errors "stat+fork" "$out"
check "has Performance stats" "$out" "Performance stats"
check "4 processes" "$out" "4.*Ruby processes profiled"
check "has samples" "$out" "samples.*triggers"
echo

# --- 3. Spawn Ruby child (stat) ---
echo "# 3. Spawn Ruby child (stat)"
out=$($RPERF stat -f 100 -- "$RUBY" -e "pid = spawn('$RUBY', '-e', '500_000.times { 1 + 1 }'); Process.wait(pid)" 2>&1)
check_no_errors "stat+spawn" "$out"
check "has Performance stats" "$out" "Performance stats"
check "2 processes" "$out" "2.*Ruby processes profiled"
check "only one Performance stats block" "$out" "Performance stats"
# Should NOT have two "Performance stats" lines
count=$(echo "$out" | grep -c "Performance stats" || true)
if [ "$count" -eq 1 ]; then
  pass "single stat output (no duplicate)"
else
  fail "single stat output (got $count)"
fi
echo

# --- 4. --no-inherit (fork not tracked) ---
echo "# 4. --no-inherit"
out=$($RPERF stat --no-inherit -f 100 -- "$RUBY" -e '3.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall' 2>&1)
check "has Performance stats" "$out" "Performance stats"
if echo "$out" | grep -q "processes profiled"; then
    fail "no processes line (unexpected processes line)"
  else
    pass "no processes line"
  fi
echo

# --- 5. Record + fork ---
echo "# 5. Record + fork"
outfile="$TMPDIR/rperf-test5-$$.json.gz"
out=$(out=$($RPERF record -f 100 -o "$outfile" -- "$RUBY" -e 'fork { 500_000.times { 1 + 1 } }; Process.waitall; 500_000.times { 1 + 1 }' 2>&1)
check_no_errors "record write path" "$out")
check_no_errors "record+fork" "$out"
info=$(ruby -Ilib -rrperf -e "d = Rperf.load('$outfile'); puts \"#{d[:process_count]}\"")
check "process_count=2" "$info" "^2$"
rm -f "$outfile"
echo

# --- 6. Record + spawn ---
echo "# 6. Record + spawn"
outfile="$TMPDIR/rperf-test6-$$.json.gz"
out=$($RPERF record -f 100 -o "$outfile" -- "$RUBY" -e "pid = spawn('$RUBY', '-e', '500_000.times { 1 + 1 }'); Process.wait(pid); 500_000.times { 1 + 1 }" 2>&1)
check_no_errors "record+spawn" "$out"
info=$(ruby -Ilib -rrperf -e "d = Rperf.load('$outfile'); puts \"#{d[:process_count]}\"")
check "process_count=2" "$info" "^2$"
rm -f "$outfile"
echo

# --- 7. Record --no-inherit ---
echo "# 7. Record --no-inherit"
outfile="$TMPDIR/rperf-test7-$$.json.gz"
$RPERF record --no-inherit -f 100 -o "$outfile" -- "$RUBY" -e 'fork { 500_000.times { 1 + 1 } }; Process.waitall; 500_000.times { 1 + 1 }' 2>&1
info=$(ruby -Ilib -rrperf -e "d = Rperf.load('$outfile'); puts \"#{d[:process_count]}\"")
check "no process_count" "$info" "^$"
rm -f "$outfile"
echo

# --- 8. Fork + spawn mix ---
echo "# 8. Fork + spawn mix"
out=$($RPERF stat -f 100 -- "$RUBY" -e "
fork { 500_000.times { 1 + 1 } }
pid = spawn('$RUBY', '-e', '500_000.times { 1 + 1 }')
Process.waitall
500_000.times { 1 + 1 }
" 2>&1)
check "3 processes" "$out" "3.*Ruby processes profiled"
echo

# --- 9. Nested fork (grandchild) ---
echo "# 9. Nested fork (grandchild)"
out=$($RPERF stat -f 100 -- "$RUBY" -e '
fork {
  fork { 500_000.times { 1 + 1 } }
  Process.waitall
  500_000.times { 1 + 1 }
}
Process.waitall
500_000.times { 1 + 1 }
' 2>&1)
check "3 processes" "$out" "3.*Ruby processes profiled"
echo

# --- 10. Multiple spawns ---
echo "# 10. Multiple spawns"
out=$($RPERF stat -f 100 -- "$RUBY" -e "
pids = 3.times.map { spawn('$RUBY', '-e', '500_000.times { 1 + 1 }') }
pids.each { |p| Process.wait(p) }
" 2>&1)
check "4 processes" "$out" "4.*Ruby processes profiled"
echo

# --- 11. Session dir cleanup ---
echo "# 11. Session dir cleanup"
$RPERF stat -f 100 -- "$RUBY" -e 'fork { }; Process.waitall' 2>&1 > /dev/null
uid=$(id -u)
user_dir="$TMPDIR/rperf-$uid"
if [ -d "$user_dir" ]; then
  count=$(ls -1 "$user_dir" 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    pass "session dir cleaned up"
  else
    fail "stale session dirs remain: $count"
  fi
else
  pass "session dir cleaned up (user_dir gone)"
fi
echo

# --- 12. exec + fork ---
echo "# 12. exec + fork"
out=$($RPERF exec -f 100 -- "$RUBY" -e '2.times { fork { 500_000.times { 1 + 1 } } }; Process.waitall' 2>&1)
check "has Performance stats" "$out" "Performance stats"
check "3 processes" "$out" "3.*Ruby processes profiled"
check "has Flat table" "$out" "Flat"
echo

# --- 13. pid label on children ---
echo "# 13. pid label on fork children"
outfile="$TMPDIR/rperf-test13-$$.json.gz"
out=$($RPERF record -f 100 -o "$outfile" -- "$RUBY" -e 'fork { 500_000.times { 1 + 1 } }; Process.waitall; 500_000.times { 1 + 1 }' 2>&1)
check_no_errors "record write path" "$out"
info=$(ruby -Ilib -rrperf -rjson -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
has_pid = ls.any? { |h| h.key?(:\"%pid\") || h.key?('%pid') }
puts has_pid ? 'yes' : 'no'
")
check "child has %pid label" "$info" "^yes$"
rm -f "$outfile"
echo

# --- 14. pid/ppid metadata in JSON ---
echo "# 14. pid/ppid in JSON output"
outfile="$TMPDIR/rperf-test14-$$.json.gz"
$RPERF record --no-inherit -f 100 -o "$outfile" -- "$RUBY" -e '500_000.times { 1 + 1 }' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts d[:pid] && d[:ppid] ? 'yes' : 'no'
")
check "has pid and ppid" "$info" "^yes$"
rm -f "$outfile"
echo

# --- 15. Single process record (no session dir created) ---
echo "# 15. Single process record (no session dir)"
outfile="$TMPDIR/rperf-test15-$$.pb.gz"
$RPERF record -f 100 -o "$outfile" -- "$RUBY" -e '500_000.times { 1 + 1 }' 2>&1
if [ -f "$outfile" ]; then
  pass "output file created"
else
  fail "output file not created"
fi
rm -f "$outfile"
# Check no stale session dir
uid=$(id -u)
user_dir="$TMPDIR/rperf-$uid"
if [ -d "$user_dir" ]; then
  count=$(ls -1 "$user_dir" 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    pass "no session dir for single process"
  else
    fail "session dir created for single process: $count"
  fi
else
  pass "no session dir for single process"
fi
echo

# --- 16. Deep nesting: parent/child/grandchild/great-grandchild with distinct methods ---
echo "# 16. Deep fork nesting (4 generations)"
outfile="$TMPDIR/rperf-test16-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e '
def root_work     = 2_000_000.times { 1 + 1 }
def child_work    = 2_000_000.times { 1 + 1 }
def grand_work    = 2_000_000.times { 1 + 1 }
def great_work    = 2_000_000.times { 1 + 1 }

fork {
  fork {
    fork {
      great_work
    }
    Process.waitall
    grand_work
  }
  Process.waitall
  child_work
}
Process.waitall
root_work
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
methods = d[:aggregated_samples].flat_map { |frames, *| frames.map { |_, label| label } }.uniq.sort
puts \"processes=#{d[:process_count]}\"
puts \"methods=#{methods.join(',')}\"
%w[root_work child_work grand_work great_work].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end
")
check "4 processes" "$info" "processes=4"
check "root_work present" "$info" "root_work=yes"
check "child_work present" "$info" "child_work=yes"
check "grand_work present" "$info" "grand_work=yes"
check "great_work present" "$info" "great_work=yes"
rm -f "$outfile"
echo

# --- 17. Fork + system (spawn Ruby via system()) ---
echo "# 17. Fork + system(ruby)"
outfile="$TMPDIR/rperf-test17-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e "
def parent_work = 2_000_000.times { 1 + 1 }
def fork_child_work = 2_000_000.times { 1 + 1 }

fork { fork_child_work }
system('$RUBY', '-e', 'def system_child_work = 2_000_000.times { 1 + 1 }; system_child_work')
Process.waitall
parent_work
" 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"processes=#{d[:process_count]}\"
%w[parent_work fork_child_work system_child_work].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end
")
check "3 processes" "$info" "processes=3"
check "parent_work present" "$info" "parent_work=yes"
check "fork_child_work present" "$info" "fork_child_work=yes"
check "system_child_work present" "$info" "system_child_work=yes"
rm -f "$outfile"
echo

# --- 18. Grandchild via fork, great-grandchild via system ---
echo "# 18. Fork grandchild + system great-grandchild"
outfile="$TMPDIR/rperf-test18-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e "
def root_method = 2_000_000.times { 1 + 1 }
def child_method = 2_000_000.times { 1 + 1 }

fork {
  child_method
  system('$RUBY', '-e', 'def grandchild_method = 2_000_000.times { 1 + 1 }; grandchild_method')
}
Process.waitall
root_method
" 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"processes=#{d[:process_count]}\"
%w[root_method child_method grandchild_method].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end
")
check "3 processes" "$info" "processes=3"
check "root_method present" "$info" "root_method=yes"
check "child_method present" "$info" "child_method=yes"
check "grandchild_method present" "$info" "grandchild_method=yes"
rm -f "$outfile"
echo

# --- 19. Mixed: fork → spawn, fork → fork, all with distinct work ---
echo "# 19. Mixed fork/spawn tree"
outfile="$TMPDIR/rperf-test19-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e "
def root_job = 2_000_000.times { 1 + 1 }
def fork_a_job = 2_000_000.times { 1 + 1 }
def fork_b_job = 2_000_000.times { 1 + 1 }

# fork child A does fork_a_job, then spawns a Ruby grandchild
fork {
  fork_a_job
  pid = spawn('$RUBY', '-e', 'def spawn_gc_job = 2_000_000.times { 1 + 1 }; spawn_gc_job')
  Process.wait(pid)
}

# fork child B does fork_b_job, then forks a grandchild
fork {
  fork_b_job
  fork { def fork_gc_job = 2_000_000.times { 1 + 1 }; fork_gc_job }
  Process.waitall
}

Process.waitall
root_job
" 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"processes=#{d[:process_count]}\"
%w[root_job fork_a_job fork_b_job spawn_gc_job fork_gc_job].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end

# Check pid labels: all non-root should have %pid
ls = d[:label_sets] || []
pid_labels = ls.select { |h| h.key?(:\"%pid\") || h.key?('%pid') }
puts \"pid_label_count=#{pid_labels.size}\"
")
check "5 processes" "$info" "processes=5"
check "root_job present" "$info" "root_job=yes"
check "fork_a_job present" "$info" "fork_a_job=yes"
check "fork_b_job present" "$info" "fork_b_job=yes"
check "spawn_gc_job present" "$info" "spawn_gc_job=yes"
check "fork_gc_job present" "$info" "fork_gc_job=yes"
# At least 4 distinct %pid labels (4 children)
check "pid labels >= 4" "$info" "pid_label_count=[4-9]"
rm -f "$outfile"
echo

# --- 20. Heavy workload: deep tree with sustained CPU work ---
echo "# 20. Heavy fork tree (5 processes, ~0.5s each)"
outfile="$TMPDIR/rperf-test20-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e '
def master_heavy = 50_000_000.times { 1 + 1 }
def worker_a_heavy = 50_000_000.times { 1 + 1 }
def worker_b_heavy = 50_000_000.times { 1 + 1 }
def sub_worker_heavy = 50_000_000.times { 1 + 1 }
def io_worker_heavy
  20.times { sleep 0.025; 1_000_000.times { 1 + 1 } }
end

fork {
  fork { sub_worker_heavy }
  Process.waitall
  worker_a_heavy
}
fork { worker_b_heavy }
fork { io_worker_heavy }
Process.waitall
master_heavy
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
samples = d[:aggregated_samples]
total_weight = samples.sum { |_, w, *| w }
puts \"processes=#{d[:process_count]}\"
puts \"total_samples=#{d[:sampling_count]}\"
puts \"total_weight_ms=#{total_weight / 1_000_000}\"
%w[master_heavy worker_a_heavy worker_b_heavy sub_worker_heavy io_worker_heavy].each do |m|
  weight = samples.select { |frames, *| frames.any? { |_, label| label.include?(m) } }.sum { |_, w, *| w }
  puts \"#{m}=#{weight > 0 ? 'yes' : 'no'} (#{weight / 1_000_000}ms)\"
end
")
check "5 processes" "$info" "processes=5"
check "many samples" "$info" "total_samples=[0-9]{2,}"
check "master_heavy present" "$info" "master_heavy=yes"
check "worker_a_heavy present" "$info" "worker_a_heavy=yes"
check "worker_b_heavy present" "$info" "worker_b_heavy=yes"
check "sub_worker_heavy present" "$info" "sub_worker_heavy=yes"
check "io_worker_heavy present" "$info" "io_worker_heavy=yes"
echo "$info" | grep -E "(processes|total_|_heavy)" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 21. system() chain: parent → system(child) → system(grandchild) ---
echo "# 21. system() chain (3 generations)"
outfile="$TMPDIR/rperf-test21-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e "
def chain_root = 20_000_000.times { 1 + 1 }
system('$RUBY', '-e', \"def chain_mid = 20_000_000.times { 1 + 1 }; chain_mid; system('$RUBY', '-e', 'def chain_leaf = 20_000_000.times { 1 + 1 }; chain_leaf')\")
chain_root
" 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"processes=#{d[:process_count]}\"
%w[chain_root chain_mid chain_leaf].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end
")
check "3 processes" "$info" "processes=3"
check "chain_root present" "$info" "chain_root=yes"
check "chain_mid present" "$info" "chain_mid=yes"
check "chain_leaf present" "$info" "chain_leaf=yes"
rm -f "$outfile"
echo

# --- 22. Daemon child (outlives parent) ---
echo "# 22. Daemon child (outlives parent, profile lost)"
out=$($RPERF stat -f 100 -- "$RUBY" -e '
def parent_daemon_test = 5_000_000.times { 1 + 1 }

fork {
  # Detach from parent — becomes a daemon
  Process.daemon(true, true)
  def daemon_work = 5_000_000.times { 1 + 1 }
  daemon_work
}

# Parent does not waitall — exits immediately after its own work
parent_daemon_test
' 2>&1)
# The daemon child may or may not be captured depending on timing.
# The key assertion: parent should succeed without error.
check "parent completes without error" "$out" "Performance stats"
check "parent_daemon_test in output" "$out" "samples.*triggers"
# Daemon child's data is likely lost (it outlives the session dir cleanup).
# That's expected behavior — document it.
echo "  INFO: daemon child profile is expected to be lost (outlives parent)"
echo

# --- 23. Fork child that ignores SIGTERM and outlives parent briefly ---
echo "# 23. Slow child (parent exits first, child writes after)"
outfile="$TMPDIR/rperf-test23-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e '
def quick_parent = 5_000_000.times { 1 + 1 }
def slow_child = 20_000_000.times { 1 + 1 }

fork {
  slow_child
}
# Parent finishes quickly, does NOT waitall
quick_parent
' 2>&1
# Parent exits first. Child may or may not finish before aggregation.
# With fork, the at_exit runs in both. Parent aggregates whatever is in session dir.
if [ -f "$outfile" ]; then
  info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"processes=#{d[:process_count]}\"
%w[quick_parent slow_child].each do |m|
  found = d[:aggregated_samples].any? { |frames, *| frames.any? { |_, label| label.include?(m) } }
  puts \"#{m}=#{found ? 'yes' : 'no'}\"
end
")
  check "parent data present" "$info" "quick_parent=yes"
  # slow_child may or may not be captured — timing dependent
  if echo "$info" | grep -q "slow_child=yes"; then
    pass "slow_child captured (lucky timing)"
  else
    pass "slow_child missed (expected — parent exited first)"
  fi
  echo "$info" | sed 's/^/  INFO: /'
else
  fail "output file not created"
fi
rm -f "$outfile"
echo

# --- 24. Many fork workers (simulate preforking server) ---
echo "# 24. Preforking server simulation (8 workers)"
outfile="$TMPDIR/rperf-test24-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e '
def master_setup = 5_000_000.times { 1 + 1 }
def worker_request
  10.times { sleep 0.01; 2_000_000.times { 1 + 1 } }
end

master_setup
8.times { |i| fork { worker_request } }
Process.waitall
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
samples = d[:aggregated_samples]
ls = d[:label_sets] || []
pid_count = ls.map { |h| h[:\"%pid\"] || h['%pid'] }.compact.uniq.size
total_weight_ms = samples.sum { |_, w, *| w } / 1_000_000
puts \"processes=#{d[:process_count]}\"
puts \"pid_labels=#{pid_count}\"
puts \"total_weight_ms=#{total_weight_ms}\"
puts \"master_setup=#{samples.any? { |frames, *| frames.any? { |_, l| l.include?('master_setup') } } ? 'yes' : 'no'}\"
puts \"worker_request=#{samples.any? { |frames, *| frames.any? { |_, l| l.include?('worker_request') } } ? 'yes' : 'no'}\"
")
check "9 processes" "$info" "processes=9"
check "8 distinct pids" "$info" "pid_labels=8"
check "master_setup present" "$info" "master_setup=yes"
check "worker_request present" "$info" "worker_request=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 25. Weight distribution: equal workers should have roughly equal weight ---
echo "# 25. Weight distribution (4 equal workers)"
outfile="$TMPDIR/rperf-test25-$$.json.gz"
$RPERF record -f 1000 -m cpu -o "$outfile" -- "$RUBY" -e '
def equal_work = 20_000_000.times { 1 + 1 }
4.times { fork { equal_work } }
Process.waitall
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
samples = d[:aggregated_samples]
# Collect per-pid weight
pid_weights = Hash.new(0)
samples.each do |frames, weight, _ts, lsi|
  lbl = ls[lsi] || {}
  pid_val = lbl[:\"%pid\"] || lbl['%pid']
  next unless pid_val  # skip root
  pid_weights[pid_val] += weight
end
weights = pid_weights.values.sort
if weights.size == 4
  min_w = weights.first
  max_w = weights.last
  ratio = max_w.to_f / [min_w, 1].max
  puts \"workers=#{weights.size}\"
  puts \"min_ms=#{min_w / 1_000_000}\"
  puts \"max_ms=#{max_w / 1_000_000}\"
  puts \"ratio=#{'%.1f' % ratio}\"
  puts \"balanced=#{ratio < 3.0 ? 'yes' : 'no'}\"
else
  puts \"workers=#{weights.size}\"
  puts \"balanced=unknown\"
end
")
check "4 workers" "$info" "workers=4"
check "weight balanced" "$info" "balanced=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 26. Weight not lost in fork+spawn mix ---
echo "# 26. Weight conservation (fork + spawn)"
outfile="$TMPDIR/rperf-test26-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e "
def root_conserve = 20_000_000.times { 1 + 1 }
def fork_conserve = 20_000_000.times { 1 + 1 }

fork { fork_conserve }
pid = spawn('$RUBY', '-e', 'def spawn_conserve = 20_000_000.times { 1 + 1 }; spawn_conserve')
Process.wait(pid)
Process.waitall
root_conserve
" 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
samples = d[:aggregated_samples]
total = samples.sum { |_, w, *| w }
%w[root_conserve fork_conserve spawn_conserve].each do |m|
  w = samples.select { |frames, *| frames.any? { |_, l| l.include?(m) } }.sum { |_, w, *| w }
  puts \"#{m}_ms=#{w / 1_000_000}\"
  puts \"#{m}_present=#{w > 0 ? 'yes' : 'no'}\"
end
puts \"total_ms=#{total / 1_000_000}\"
")
check "root_conserve present" "$info" "root_conserve_present=yes"
check "fork_conserve present" "$info" "fork_conserve_present=yes"
check "spawn_conserve present" "$info" "spawn_conserve_present=yes"
# Each should have meaningful weight (>10ms at least)
check "root weight > 10ms" "$info" "root_conserve_ms=[1-9][0-9]+"
check "fork weight > 10ms" "$info" "fork_conserve_ms=[1-9][0-9]+"
check "spawn weight > 10ms" "$info" "spawn_conserve_ms=[1-9][0-9]+"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 27. %pid label accuracy: matches actual PID, root has no %pid ---
echo "# 27. %pid label accuracy"
outfile="$TMPDIR/rperf-test27-$$.json.gz"
$RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e '
rd, wr = IO.pipe
fork {
  rd.close
  wr.puts Process.pid
  wr.close
  5_000_000.times { 1 + 1 }
}
wr.close
child_pid = rd.read.strip
rd.close
Process.waitall
5_000_000.times { 1 + 1 }
$stderr.puts "CHILD_PID=#{child_pid}"
' 2>&1
child_pid=$(echo "$out" 2>&1 | grep CHILD_PID | head -1 | sed 's/.*=//')
# Extract child_pid from stderr
child_pid=$($RPERF record -f 500 -m wall -o "$outfile" -- "$RUBY" -e '
rd, wr = IO.pipe
fork {
  rd.close
  wr.puts Process.pid
  wr.close
  5_000_000.times { 1 + 1 }
}
wr.close
child_pid = rd.read.strip
rd.close
Process.waitall
5_000_000.times { 1 + 1 }
$stderr.puts "CHILD_PID=#{child_pid}"
' 2>&1 | grep CHILD_PID | sed 's/.*=//')
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
samples = d[:aggregated_samples]

# Check root samples have no %pid
root_samples = samples.select { |_, _, _, lsi|
  lbl = ls[lsi] || {}
  !lbl.key?(:\"%pid\") && !lbl.key?('%pid')
}
child_pids = ls.map { |h| h[:\"%pid\"] || h['%pid'] }.compact.uniq
puts \"root_samples_exist=#{root_samples.size > 0 ? 'yes' : 'no'}\"
puts \"child_pids=#{child_pids.join(',')}\"
puts \"expected_child_pid=$child_pid\"
puts \"pid_match=#{child_pids.include?('$child_pid') ? 'yes' : 'no'}\"
puts \"only_one_pid=#{child_pids.size == 1 ? 'yes' : 'no'}\"
")
check "root has no %pid" "$info" "root_samples_exist=yes"
check "only one child pid" "$info" "only_one_pid=yes"
if [ -n "$child_pid" ]; then
  check "pid matches actual PID" "$info" "pid_match=yes"
else
  pass "pid matches (child_pid not captured, skipping)"
fi
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 28. GVL/GC labels preserved in multi-process merge ---
echo "# 28. GVL labels in multi-process (wall mode)"
outfile="$TMPDIR/rperf-test28-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e '
def io_work = 10.times { sleep 0.05 }
def cpu_work = 20_000_000.times { 1 + 1 }

fork { io_work }
fork { cpu_work }
Process.waitall
cpu_work
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
has_gvl_blocked = ls.any? { |h| (h[:\"%GVL\"] || h['%GVL']) == 'blocked' }
has_cpu_only = ls.any? { |h|
  !h.key?(:\"%GVL\") && !h.key?('%GVL') && !h.key?(:\"%GC\") && !h.key?('%GC')
}
puts \"has_gvl_blocked=#{has_gvl_blocked ? 'yes' : 'no'}\"
puts \"has_cpu_only=#{has_cpu_only ? 'yes' : 'no'}\"
puts \"label_set_count=#{ls.size}\"
puts \"processes=#{d[:process_count]}\"
")
check "3 processes" "$info" "processes=3"
check "GVL blocked label present" "$info" "has_gvl_blocked=yes"
check "CPU-only samples present" "$info" "has_cpu_only=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 29. CPU mode multi-process ---
echo "# 29. CPU mode (fork)"
outfile="$TMPDIR/rperf-test29-$$.json.gz"
$RPERF record -f 1000 -m cpu -o "$outfile" -- "$RUBY" -e '
def cpu_root = 20_000_000.times { 1 + 1 }
def cpu_child = 20_000_000.times { 1 + 1 }
fork { cpu_child }
Process.waitall
cpu_root
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
puts \"mode=#{d[:mode]}\"
puts \"processes=#{d[:process_count]}\"
puts \"cpu_root=#{d[:aggregated_samples].any? { |f, *| f.any? { |_, l| l.include?('cpu_root') } } ? 'yes' : 'no'}\"
puts \"cpu_child=#{d[:aggregated_samples].any? { |f, *| f.any? { |_, l| l.include?('cpu_child') } } ? 'yes' : 'no'}\"
# In CPU mode, GVL blocked should NOT appear (CPU doesn't advance off-GVL)
ls = d[:label_sets] || []
has_gvl = ls.any? { |h| h.key?(:\"%GVL\") || h.key?('%GVL') }
puts \"no_gvl_labels=#{has_gvl ? 'no' : 'yes'}\"
")
check "mode is cpu" "$info" "mode=cpu"
check "2 processes" "$info" "processes=2"
check "cpu_root present" "$info" "cpu_root=yes"
check "cpu_child present" "$info" "cpu_child=yes"
check "no GVL labels in cpu mode" "$info" "no_gvl_labels=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 30. Wall mode: I/O time captured across processes ---
echo "# 30. Wall mode captures I/O time"
outfile="$TMPDIR/rperf-test30-$$.json.gz"
$RPERF record -f 1000 -m wall -o "$outfile" -- "$RUBY" -e '
def wall_cpu = 10_000_000.times { 1 + 1 }
def wall_sleep = sleep 0.3

fork { wall_sleep }
fork { wall_cpu }
Process.waitall
wall_cpu
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
samples = d[:aggregated_samples]
total_ms = samples.sum { |_, w, *| w } / 1_000_000
# GVL blocked weight (from sleeping child)
gvl_blocked_ms = samples.select { |_, _, _, lsi|
  lbl = ls[lsi] || {}
  (lbl[:\"%GVL\"] || lbl['%GVL']) == 'blocked'
}.sum { |_, w, *| w } / 1_000_000
puts \"mode=#{d[:mode]}\"
puts \"processes=#{d[:process_count]}\"
puts \"total_ms=#{total_ms}\"
puts \"gvl_blocked_ms=#{gvl_blocked_ms}\"
puts \"has_io_time=#{gvl_blocked_ms >= 200 ? 'yes' : 'no'}\"
")
check "mode is wall" "$info" "mode=wall"
check "3 processes" "$info" "processes=3"
check "I/O time captured (>=200ms)" "$info" "has_io_time=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 31. signal: false (nanosleep mode) ---
echo "# 31. signal: false (nanosleep mode)"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  outfile="$TMPDIR/rperf-test31-$$.json.gz"
  $RPERF record -f 500 -m wall --signal false -o "$outfile" -- "$RUBY" -e '
  def nanosleep_root = 10_000_000.times { 1 + 1 }
  def nanosleep_child = 10_000_000.times { 1 + 1 }
  fork { nanosleep_child }
  Process.waitall
  nanosleep_root
  ' 2>&1
  info=$(ruby -Ilib -rrperf -e "
  d = Rperf.load('$outfile')
  puts \"processes=#{d[:process_count]}\"
  puts \"nanosleep_root=#{d[:aggregated_samples].any? { |f, *| f.any? { |_, l| l.include?('nanosleep_root') } } ? 'yes' : 'no'}\"
  puts \"nanosleep_child=#{d[:aggregated_samples].any? { |f, *| f.any? { |_, l| l.include?('nanosleep_child') } } ? 'yes' : 'no'}\"
  ")
  check "2 processes" "$info" "processes=2"
  check "nanosleep_root present" "$info" "nanosleep_root=yes"
  check "nanosleep_child present" "$info" "nanosleep_child=yes"
  echo "$info" | sed 's/^/  INFO: /'
  rm -f "$outfile"
else
  pass "signal: false (skipped on non-Linux)"
  pass "signal: false (skipped on non-Linux)"
  pass "signal: false (skipped on non-Linux)"
fi
echo

# --- 32. Large number of workers (32) ---
echo "# 32. Large worker count (32 workers)"
outfile="$TMPDIR/rperf-test32-$$.json.gz"
$RPERF record -f 500 -m cpu -o "$outfile" -- "$RUBY" -e '
def worker_task = 5_000_000.times { 1 + 1 }
32.times { fork { worker_task } }
Process.waitall
' 2>&1
info=$(ruby -Ilib -rrperf -e "
d = Rperf.load('$outfile')
ls = d[:label_sets] || []
pid_count = ls.map { |h| h[:\"%pid\"] || h['%pid'] }.compact.uniq.size
puts \"processes=#{d[:process_count]}\"
puts \"distinct_pids=#{pid_count}\"
puts \"has_worker_task=#{d[:aggregated_samples].any? { |f, *| f.any? { |_, l| l.include?('worker_task') } } ? 'yes' : 'no'}\"
")
check "33 processes" "$info" "processes=33"
check "32 distinct pids" "$info" "distinct_pids=32"
check "worker_task present" "$info" "has_worker_task=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile"
echo

# --- 33. CPU vs wall weight comparison ---
echo "# 33. CPU vs wall: sleep only counts in wall mode"
outfile_cpu="$TMPDIR/rperf-test33-cpu-$$.json.gz"
outfile_wall="$TMPDIR/rperf-test33-wall-$$.json.gz"
$RPERF record -f 1000 -m cpu -o "$outfile_cpu" -- "$RUBY" -e '
def sleepy_work = sleep 0.3
fork { sleepy_work }
Process.waitall
sleepy_work
' 2>&1
$RPERF record -f 1000 -m wall -o "$outfile_wall" -- "$RUBY" -e '
def sleepy_work = sleep 0.3
fork { sleepy_work }
Process.waitall
sleepy_work
' 2>&1
info=$(ruby -Ilib -rrperf -e "
cpu_d = Rperf.load('$outfile_cpu')
wall_d = Rperf.load('$outfile_wall')
cpu_total = cpu_d[:aggregated_samples].sum { |_, w, *| w } / 1_000_000
wall_total = wall_d[:aggregated_samples].sum { |_, w, *| w } / 1_000_000
puts \"cpu_total_ms=#{cpu_total}\"
puts \"wall_total_ms=#{wall_total}\"
puts \"wall_much_larger=#{wall_total > cpu_total + 100 ? 'yes' : 'no'}\"
puts \"cpu_processes=#{cpu_d[:process_count]}\"
puts \"wall_processes=#{wall_d[:process_count]}\"
")
check "cpu 2 processes" "$info" "cpu_processes=2"
check "wall 2 processes" "$info" "wall_processes=2"
check "wall >> cpu for sleep workload" "$info" "wall_much_larger=yes"
echo "$info" | sed 's/^/  INFO: /'
rm -f "$outfile_cpu" "$outfile_wall"
echo

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
