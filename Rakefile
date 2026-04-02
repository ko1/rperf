require 'bundler/gem_tasks'

# Override bundler's release task to only tag + push (gem push is handled by GitHub Actions trusted publishing)
Rake::Task["release"].clear
task :release do
  require_relative "lib/rperf/version"
  tag = "v#{Rperf::VERSION}"

  if system("git", "rev-parse", tag, err: File::NULL, out: File::NULL)
    abort "Tag #{tag} already exists"
  end

  sh "git", "tag", tag
  sh "git", "push", "origin", "master", "--tags"
  puts "Pushed #{tag} — GitHub Actions will publish the gem"
end
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

task default: [:compile, :manual, :test]