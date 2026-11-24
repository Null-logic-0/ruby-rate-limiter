# frozen_string_literal: true

# Replays the same requests against a token bucket and a leaky bucket (meter)
# and prints their state side by side.

# bundle exec ruby examples/compare_buckets.rb

require_relative '../lib/rate_limiter'

# A clock the script moves by hand, so the timeline is exact.
class ScriptClock
  attr_accessor :now

  def initialize
    @now = 0.0
  end
end

clock = ScriptClock.new
token_bucket = RateLimiter::Algorithms::TokenBucket.new(capacity: 10, refill_rate: 1, clock: clock)
leaky_bucket = RateLimiter::Algorithms::LeakyBucketMeter.new(capacity: 10, leak_rate: 1, clock: clock)
key = 'ip:203.0.113.7'

# [time in seconds, number of requests]
timeline = [[0.0, 11], [0.4, 1], [1.0, 1], [100.0, 1]]

def describe(result)
  decision = result.allowed? ? 'allow ' : 'reject'
  wait = result.allowed? ? '' : format('retry in %.1fs', result.retry_after)
  format('%<decision>s %-14<wait>s', decision: decision, wait: wait)
end

puts format(
  '%<time>-6s %<number>-3s | %<token_bucket>-21s %<tokens>-8s | %<leaky_bucket>-21s %<level>-8s',
  time: 'time',
  number: '#',
  token_bucket: 'token bucket',
  tokens: 'tokens',
  leaky_bucket: 'leaky bucket (meter)',
  level: 'level'
)
puts '-' * 81

timeline.each do |time, count|
  clock.now = time

  count.times do |index|
    token_result = token_bucket.acquire(key)
    leaky_result = leaky_bucket.acquire(key)

    puts format(
      '%<time>5.1fs %<index>3d | %<token_description>-21s %<token_balance>8.2f | %<leaky_description>-21s %<leaky_level>8.2f',
      time: time,
      index: index + 1,
      token_description: describe(token_result),
      token_balance: token_bucket.tokens(key),
      leaky_description: describe(leaky_result),
      leaky_level: leaky_bucket.level(key)
    )
  end
end
