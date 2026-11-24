# frozen_string_literal: true

# Replays the same random traffic against the sliding window counter and the
# exact sliding window log, and compares what each admitted.

# bundle exec ruby examples/counter_accuracy.rb

require_relative '../lib/rate_limiter'

# A clock the script moves by hand.
class ScriptClock
  attr_reader :now

  def initialize
    @now = 0.0
  end

  def advance(seconds)
    @now += seconds
  end
end

# Two hours of random traffic averaging `per_minute` requests per minute.
# Returns how many requests were admitted and the most admitted within any
# 60-second span.
def simulate(limiter_class, limit:, per_minute:, minutes: 120, seed: 1)
  clock = ScriptClock.new
  limiter = limiter_class.new(limit: limit, window: 60, clock: clock)
  random = Random.new(seed)
  max_step = (120.0 / per_minute / 0.25).round
  live = []
  admitted = 0
  busiest = 0

  until clock.now >= minutes * 60
    clock.advance(random.rand(0..max_step) * 0.25)
    live.shift while live.any? && live.first + 60 <= clock.now
    next unless limiter.acquire('ip:203.0.113.7').allowed?

    admitted += 1
    live << clock.now
    busiest = [busiest, live.size].max
  end

  [admitted, busiest]
end

puts format(
  '%<limit>-6s %<traffic>-8s | %<counter>-22s | %<log>-22s | %<comparison>s',
  limit: 'limit',
  traffic: 'traffic',
  counter: 'counter: admitted/peak',
  log: 'log: admitted/peak',
  comparison: 'counter vs log'
)
puts '-' * 86

[[100, 50], [100, 100], [100, 200], [10, 10]].each do |limit, per_minute|
  counter = simulate(RateLimiter::Algorithms::SlidingWindowCounter, limit: limit, per_minute: per_minute)
  log = simulate(RateLimiter::Algorithms::SlidingWindowLog, limit: limit, per_minute: per_minute)

  puts format(
    '%<limit>-6d %<per_minute>3d/min | %<counter_admitted>8d / %<counter_peak>-11d | %<log_admitted>8d / %<log_peak>-11d | %<difference>+.1f%%',
    limit: limit,
    per_minute: per_minute,
    counter_admitted: counter[0],
    counter_peak: counter[1],
    log_admitted: log[0],
    log_peak: log[1],
    difference: 100.0 * (counter[0] - log[0]) / log[0]
  )
end
