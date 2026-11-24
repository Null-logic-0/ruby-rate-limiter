# frozen_string_literal: true

# Sends real HTTP traffic to a running server and prints accepted
# vs 429 per second.

#   bundle exec ruby examples/load_test.rb [URL] [USERS] [SECONDS]
#   bundle exec ruby examples/load_test.rb http://127.0.0.1:8080/limited 10 10

require 'net/http'
require 'uri'

url = URI(ARGV.fetch(0, 'http://127.0.0.1:8080/limited'))
users = Integer(ARGV.fetch(1, '10'))
duration = Integer(ARGV.fetch(2, '10'))

clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
started = clock.call
deadline = started + duration
outcomes = Queue.new # [second the request started in, HTTP status]

# Each user keeps one connection and sends requests back to back.
workers = Array.new(users) do
  Thread.new do
    Net::HTTP.start(url.host, url.port) do |http|
      while (sent_at = clock.call) < deadline
        status = http.get(url.request_uri).code.to_i
        outcomes << [(sent_at - started).floor, status]
      end
    end
  end
end
workers.each(&:join)

results = Array.new(outcomes.size) { outcomes.pop }
by_second = results.group_by(&:first)

puts format(
  '%<second>-6s %<accepted>8s %<rate_limited>8s %<other>8s  %<accepted_per_second>s',
  second: 'second',
  accepted: 'accepted',
  rate_limited: '429',
  other: 'other',
  accepted_per_second: 'accepted per second'
)
duration.times do |second|
  statuses = by_second.fetch(second, []).map(&:last)
  accepted = statuses.count { |status| status.between?(200, 299) }
  limited = statuses.count(429)
  other = statuses.size - accepted - limited
  puts format(
    '%<second>-6d %<accepted>8d %<limited>8d %<other>8d  %<bar>s',
    second: second,
    accepted: accepted,
    limited: limited,
    other: other,
    bar: '#' * accepted
  )
end

accepted = results.count { |_second, status| status.between?(200, 299) }
puts format(
  'total  %<accepted>8d %<limited>8d %<other>8d  (%<users>d users, %<rate>.0f requests/s)',
  accepted: accepted,
  limited: results.count { |_second, status| status == 429 },
  other: results.count { |_second, status| !status.between?(200, 299) && status != 429 },
  users: users,
  rate: results.size.fdiv(duration)
)
