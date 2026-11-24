# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

desc 'Run the whole suite with coverage (report in coverage/index.html)'
task :coverage do
  ENV['COVERAGE'] = '1'
  Rake::Task[:spec].invoke
end

task default: :spec
