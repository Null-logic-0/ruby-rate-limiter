# frozen_string_literal: true

# Two servers, one client, 60 requests/minute: first in memory
# (each server counts alone), then shared through Redis.
#
#   docker run --rm -p 6379:6379 redis:8   (another terminal)
#   bundle exec ruby examples/shared_limit.rb

require 'redis'
require_relative '../lib/rate_guard'

REDIS_URL = ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379')
CLIENT = 'ip:203.0.113.7'

# One server: its own limiter and Redis connection.
def build_server(redis: nil)
  config = RateGuard::Configuration.new
  config.algorithm = :sliding_window_counter
  config.limit = 60
  config.window = 60
  config.redis = redis
  RateGuard.limiter(config)
end

def demo(title, server_a, server_b)
  puts title
  allowed = 60.times.count { server_a.acquire(CLIENT).allowed? }
  puts "  server A: #{allowed} of 60 requests allowed"

  result = server_b.acquire(CLIENT)
  outcome = if result.allowed?
              'allowed (200): the client just got a second allowance'
            else
              "rejected (429), retry in #{result.retry_after.ceil}s"
            end
  puts "  server B: request 61 -> #{outcome}"
end

demo('In memory (each server keeps its own counters):', build_server, build_server)

server_a = build_server(redis: Redis.new(url: REDIS_URL))
server_b = build_server(redis: Redis.new(url: REDIS_URL))
Redis.new(url: REDIS_URL).del(server_a.redis_key(CLIENT)) # start this demo from zero
demo('Redis (both servers share one counter):', server_a, server_b)
