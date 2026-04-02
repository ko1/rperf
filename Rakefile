require 'bundler/gem_tasks'
require "rake/extensiontask"
require "rake/testtask"

Rake::ExtensionTask.new("rperf") do |ext|
  ext.lib_dir = "tmp/ignore_lib"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/test_*.rb"]
end

desc "Build docs/manual from docs/manual_src using ligarb"
task :manual do
  cd "docs/manual_src" do
    sh "ligarb", "build"
  end
end

desc "Release: push master, create tag, push tag (triggers CI gem publish)"
task :rel do
  require_relative "lib/rperf/version"
  tag = "v#{Rperf::VERSION}"

  abort "Tag #{tag} already exists" if system("git", "rev-parse", tag, err: File::NULL, out: File::NULL)
  abort "Uncommitted changes" unless system("git", "diff", "--quiet", "HEAD")

  sh "git", "push", "origin", "master"
  sh "git", "tag", tag
  sh "git", "push", "origin", tag
  puts "Pushed #{tag} — GitHub Actions will publish the gem"
end

task default: [:compile, :manual, :test]