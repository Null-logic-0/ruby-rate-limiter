# frozen_string_literal: true

# Configure by name, build limiters, and see errors for bad settings.

#   bundle exec ruby examples/configuration.rb

require_relative '../lib/rate_guard'

RateGuard.configure do |config|
  config.algorithm = :sliding_window_log
  config.limit = 3
  config.window = 60
end

limiter = RateGuard.limiter
puts "Built: #{limiter.class}"

4.times do
  result = limiter.acquire('ip:203.0.113.7')

  puts format(
    '  allowed=%<allowed>-5s remaining=%<remaining>d retry_after=%<retry_after>.0fs',
    allowed: result.allowed?,
    remaining: result.remaining,
    retry_after: result.retry_after
  )
end

puts 'Invalid settings:'
begin
  RateGuard.configure do |config|
    config.algorithm = :leaky_bucket
    config.limit = 0
  end
rescue RateGuard::ConfigurationError => e
  puts "  #{e.message}"
end
puts "  still using: #{RateGuard.configuration.algorithm}"

puts 'Wrong interface:'
RateGuard.configure do |config|
  config.algorithm = :leaky_bucket_queue
  config.limit = 5
  config.window = 10
end

begin
  RateGuard.limiter
rescue RateGuard::ConfigurationError => e
  puts "  #{e.message}"
end
puts "  RateGuard.queue built: #{RateGuard.queue.class}"
