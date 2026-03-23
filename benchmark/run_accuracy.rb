#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-run all accuracy evaluations.
# Saves raw per-method data to data/accuracy_raw.csv
# and summary data to data/accuracy_summary.csv.

require "csv"
require "open3"
require "etc"

OUTPUT_DIR = File.join(__dir__, "data")
RAW_FILE = File.join(OUTPUT_DIR, "accuracy_raw.csv")
SUMMARY_FILE = File.join(OUTPUT_DIR, "accuracy_summary.csv")
CHECK_ACCURACY = File.join(__dir__, "check_accuracy.rb")

SCENARIOS = {
  "rw"     => { file: "scenarios_rw.json",     ids: [9] },
  "cw"     => { file: "scenarios_cw.json",     ids: [9] },
  "csleep" => { file: "scenarios_csleep.json", ids: [9] },
  "cwait"  => { file: "scenarios_cwait.json",  ids: [9] },
  "mixed"  => { file: "scenarios_mixed.json",  ids: [6] },
  "ratio"  => { file: "scenarios_ratio.json",  ids: [1] },
}

PROFILERS = ["rperf", "stackprof", "vernier", "pf2"]
MODES = ["cpu", "wall"]
FREQUENCIES = [100, 1000]

Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)

# Write CSV header
CSV.open(RAW_FILE, "w") do |csv|
  csv << %w[profiler mode frequency load scenario_type scenario_id method expected actual error]
end

ruby_bin = RbConfig.ruby

def run_matrix(ruby_bin, load:, load_label:)
  SCENARIOS.each do |type, cfg|
    cfg[:ids].each do |sid|
      PROFILERS.each do |profiler|
        MODES.each do |mode|
          # vernier only supports wall mode
          next if profiler == "vernier" && mode == "cpu"

          FREQUENCIES.each do |freq|
            $stderr.puts "  #{profiler} #{mode} #{freq}Hz #{type}##{sid}"

            args = [ruby_bin, CHECK_ACCURACY,
                    "-f", cfg[:file], "-P", profiler, "-m", mode,
                    "-F", freq.to_s, "--csv", RAW_FILE]
            args << "-l" if load
            args << sid.to_s

            stdout, stderr, status = Open3.capture3(*args, chdir: File.dirname(CHECK_ACCURACY))

            unless status.success?
              $stderr.puts "    FAILED (exit #{status.exitstatus})"
            end
          end
        end
      end
    end
  end
end

# Phase 1: No load
$stderr.puts "=== No Load ==="
run_matrix(ruby_bin, load: false, load_label: "none")

# Phase 2: Under load
$stderr.puts "\n=== Under CPU Load (#{Etc.nprocessors} cores) ==="
run_matrix(ruby_bin, load: true, load_label: "full")

$stderr.puts "\nRaw data saved to #{RAW_FILE}"

# Generate summary CSV
$stderr.puts "Generating summary..."

raw_rows = CSV.read(RAW_FILE, headers: true)
groups = raw_rows.group_by { |r| [r["profiler"], r["mode"], r["frequency"], r["load"], r["scenario_type"], r["scenario_id"]] }

CSV.open(SUMMARY_FILE, "w") do |csv|
  csv << %w[profiler mode frequency load scenario_type scenario_id avg_error method_count]

  groups.sort.each do |key, rows|
    errors = rows.map { |r| r["error"].to_f }
    avg = errors.sum / errors.size
    csv << key + [avg.round(6), rows.size]
  end
end

$stderr.puts "Summary saved to #{SUMMARY_FILE}"
