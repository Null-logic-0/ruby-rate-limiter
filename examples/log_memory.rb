# frozen_string_literal: true

# Measures how much memory each algorithm's state needs when 10,000 clients
# each use their full allowance of 100 requests per minute.

# bundle exec ruby examples/log_memory.rb

require 'objspace'
require_relative '../lib/rate_limiter'

CLIENTS = 10_000
LIMIT = 100

# Bytes of Ruby heap memory retained by whatever the block builds.
def retained_bytes
  GC.start
  before = ObjectSpace.memsize_of_all
  kept = yield
  GC.start
  [ObjectSpace.memsize_of_all - before, kept]
end

limiters = {
  'Sliding window log' => -> { RateLimiter::Algorithms::SlidingWindowLog.new(limit: LIMIT, window: 60) },
  'Fixed window' => -> { RateLimiter::Algorithms::FixedWindowCounter.new(limit: LIMIT, window: 60) }
}

puts format(
  '%<algorithm>-20s %<total>12s %<per_client>16s',
  algorithm: 'algorithm',
  total: 'total',
  per_client: 'per client'
)

limiters.each do |name, build|
  bytes, _limiter = retained_bytes do
    limiter = build.call
    CLIENTS.times do |client|
      key = "ip:10.0.#{client / 256}.#{client % 256}"
      LIMIT.times { limiter.acquire(key) }
    end
    limiter
  end

  puts format(
    '%<name>-20s %<megabytes>9.1f MB %<bytes_per_client>13d B',
    name: name,
    megabytes: bytes / 1_048_576.0,
    bytes_per_client: bytes / CLIENTS
  )
end
