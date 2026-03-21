require 'bundler/gem_tasks'
require "rake/extensiontask"
require "rake/testtask"

Rake::ExtensionTask.new("sperf") do |ext|
  ext.lib_dir = "lib"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/test_*.rb"]
end

task default: [:compile, :test]
