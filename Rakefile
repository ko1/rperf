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

task default: [:compile, :manual, :test]