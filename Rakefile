# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

desc 'Run the whole suite with coverage (report in coverage/index.html)'
task :coverage do
  ENV['COVERAGE'] = '1'
  Rake::Task[:spec].invoke
end

desc 'Compare every algorithm: speed, memory, threads (BENCH_OPS / BENCH_ROUNDS to resize)'
task :benchmark do
  ruby 'benchmark/compare.rb'
end

task default: :spec
