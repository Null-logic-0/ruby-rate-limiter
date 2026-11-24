# frozen_string_literal: true

# Shows the fixed window's boundary burst: a client sends 60 requests just
# before a minute ends and 60 more just after, against a limit of 60/minute.

# bundle exec ruby examples/boundary_burst.rb

require_relative '../lib/rate_limiter'

# A clock the script moves by hand, so the timeline is exact.
class ScriptClock
  attr_accessor :now
end

clock = ScriptClock.new
fixed = RateLimiter::Algorithms::FixedWindowCounter.new(limit: 60, window: 60, clock: clock)
bucket = RateLimiter::Algorithms::TokenBucket.new(capacity: 60, refill_rate: 1, clock: clock)
key = 'ip:203.0.113.7'
bursts = [Time.utc(2026, 11, 24, 17, 47, 59.5), Time.utc(2026, 11, 24, 17, 48, 0.1)]
totals = { fixed: 0, bucket: 0 }

bursts.each do |time|
  clock.now = time.to_f
  fixed_allowed = 60.times.count { fixed.acquire(key).allowed? }
  bucket_allowed = 60.times.count { bucket.acquire(key).allowed? }

  totals[:fixed] += fixed_allowed
  totals[:bucket] += bucket_allowed
  puts format(
    '%<time>s  60 requests -> fixed window allowed %<fixed_allowed>2d, token bucket allowed %<bucket_allowed>2d',
    time: time.strftime('%H:%M:%S.%L'),
    fixed_allowed: fixed_allowed,
    bucket_allowed: bucket_allowed
  )
end

puts format(
  'Total within 0.6 s: fixed window %<fixed>d, token bucket %<bucket>d (limit 60 per minute)',
  fixed: totals[:fixed],
  bucket: totals[:bucket]
)
