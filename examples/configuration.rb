# frozen_string_literal: true

# Configures the library by name, builds limiters from the configuration,
# and shows the errors you get for invalid settings.

#   bundle exec ruby examples/configuration.rb

require_relative '../lib/rate_limiter'

RateLimiter.configure do |config|
  config.algorithm = :sliding_window_log
  config.limit = 3
  config.window = 60
end

limiter = RateLimiter.limiter
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
  RateLimiter.configure do |config|
    config.algorithm = :leaky_bucket
    config.limit = 0
  end
rescue RateLimiter::ConfigurationError => e
  puts "  #{e.message}"
end
puts "  still using: #{RateLimiter.configuration.algorithm}"

puts 'Wrong interface:'
RateLimiter.configure do |config|
  config.algorithm = :leaky_bucket_queue
  config.limit = 5
  config.window = 10
end

begin
  RateLimiter.limiter
rescue RateLimiter::ConfigurationError => e
  puts "  #{e.message}"
end
puts "  RateLimiter.queue built: #{RateLimiter.queue.class}"
