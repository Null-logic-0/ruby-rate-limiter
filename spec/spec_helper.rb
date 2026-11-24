# frozen_string_literal: true

# Coverage must start first. Only with COVERAGE=1 (whole suite).
if ENV['COVERAGE']
  require 'simplecov'

  SimpleCov.start do
    enable_coverage :branch
    add_filter '/spec/'
    add_group 'Algorithms', 'lib/rate_guard/algorithms'
    add_group 'Middleware', 'lib/rate_guard/middleware'
    add_group 'App', 'app/'
    minimum_coverage line: 98, branch: 95
  end
end

ENV['RACK_ENV'] = 'test'

require 'rate_guard'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!

  config.order = :random
  Kernel.srand config.seed
end
