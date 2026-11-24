# frozen_string_literal: true

require 'redis'
require 'securerandom'

# Examples tagged :redis talk to a real Redis at REDIS_URL. When none is
# reachable they are skipped, so the rest of the suite runs without one; set
# REQUIRE_REDIS=1 (e.g. in CI) to make that a failure instead.
module RedisHelpers
  def redis_url
    ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15')
  end

  def redis
    @redis ||= Redis.new(url: redis_url, timeout: 0.5)
  end

  # Every example writes under its own prefix and deletes only those keys,
  # so the tests never touch anyone else's data in that Redis.
  def redis_namespace
    @redis_namespace ||= "rate_limiter_test_#{SecureRandom.hex(4)}"
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
