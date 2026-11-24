# frozen_string_literal: true

require 'redis'
require 'securerandom'

# :redis examples use REDIS_URL and are skipped if Redis is down.
# REQUIRE_REDIS=1 makes that a failure (for CI).
module RedisHelpers
  def redis_url
    ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15')
  end

  def redis
    @redis ||= Redis.new(url: redis_url, timeout: 0.5)
  end

  # Each example uses its own key prefix and deletes only those keys.
  def redis_namespace
    @redis_namespace ||= "rate_guard_test_#{SecureRandom.hex(4)}"
  end
end

RSpec.configure do |config|
  config.include RedisHelpers, :redis

  config.before(:each, :redis) do
    redis.ping
  rescue Redis::BaseConnectionError => e
    raise if ENV['REQUIRE_REDIS']

    skip "no Redis at #{redis_url} (#{e.class}); start one with: docker run --rm -p 6379:6379 redis:8"
  end

  config.after(:each, :redis) do
    keys = redis.scan_each(match: "#{redis_namespace}:*").to_a
    redis.del(*keys) unless keys.empty?
  rescue Redis::BaseConnectionError
    nil
  end
end
