#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "fileutils"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
DEFAULT_OUT_DIR = File.join(ROOT, "tmp", "repro_exit_170")
DEFAULT_CMD = [RbConfig.ruby, "-Ilib:test", "-e", "ARGV.each{|f| require f}", *Dir.glob("test/test_*.rb")].freeze

options = {
  iterations: 1000,
  out_dir: DEFAULT_OUT_DIR,
  cmd: DEFAULT_CMD.dup,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/repro_exit_170.rb [options] [-- command ...]"

  opts.on("-n", "--iterations N", Integer, "Number of iterations (default: 1000)") do |v|
    options[:iterations] = v
  end

  opts.on("-o", "--out-dir DIR", "Directory for captured logs (default: tmp/repro_exit_170)") do |v|
    options[:out_dir] = File.expand_path(v, ROOT)
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end

begin
  parser.order!(ARGV)
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
  exit 1
end

options[:cmd] = ARGV unless ARGV.empty?

if options[:iterations] <= 0
  warn "iterations must be positive"
  exit 1
end

if options[:cmd].empty?
  warn "no command specified"
  exit 1
end

FileUtils.mkdir_p(options[:out_dir])

puts "Running #{options[:cmd].inspect} up to #{options[:iterations]} times"
puts "Logs: #{options[:out_dir]}"

options[:iterations].times do |i|
  iter = i + 1
  stdout_str, stderr_str, status = Open3.capture3(*options[:cmd], chdir: ROOT)

  if status.success?
    puts "[#{iter}/#{options[:iterations]}] ok"
    next
  end

  stamp = format("iter_%04d", iter)
  File.write(File.join(options[:out_dir], "#{stamp}.stdout.log"), stdout_str)
  File.write(File.join(options[:out_dir], "#{stamp}.stderr.log"), stderr_str)
  File.write(
    File.join(options[:out_dir], "#{stamp}.meta.txt"),
    <<~META
      iteration=#{iter}
      command=#{options[:cmd].inspect}
      exitstatus=#{status.exitstatus.inspect}
      termsig=#{status.termsig.inspect}
      signaled=#{status.signaled?}
      success=#{status.success?}
    META
  )

  warn "[#{iter}/#{options[:iterations]}] failed: exitstatus=#{status.exitstatus.inspect} termsig=#{status.termsig.inspect}"
  warn "stdout -> #{File.join(options[:out_dir], "#{stamp}.stdout.log")}"
  warn "stderr -> #{File.join(options[:out_dir], "#{stamp}.stderr.log")}"
  warn "meta   -> #{File.join(options[:out_dir], "#{stamp}.meta.txt")}"

  if status.exitstatus == 170
    warn "exit 170 detected; likely 128 + signal 42 (SIGRTMIN+8 on many Linux systems)"
  elsif status.signaled?
    warn "terminated by signal #{status.termsig}"
  end

  exit(status.exitstatus || 1)
end

puts "Completed without failure"
