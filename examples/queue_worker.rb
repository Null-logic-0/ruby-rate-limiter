# frozen_string_literal: true

# A producer submits 8 jobs at once to a queue that holds 5 and releases
# 2 per second. A worker thread processes them at exactly that rate.
#
#   bundle exec ruby examples/queue_worker.rb

require_relative '../lib/rate_limiter'

queue = RateLimiter::Algorithms::LeakyBucketQueue.new(capacity: 5, leak_rate: 2)
key = 'outbound:sms-provider'
started_at = RateLimiter::Clock::Monotonic.now
elapsed = -> { format('%4.1fs', RateLimiter::Clock::Monotonic.now - started_at) }

puts 'Producer'
8.times do |number|
  job = "job-#{number + 1}"
  admission = queue.enqueue(key, job)

  if admission.accepted?
    puts format(
      '  %<job>s accepted  position %<position>d, estimated wait %<wait>.1fs',
      job: job,
      position: admission.position,
      wait: admission.wait
    )
  else
    puts format(
      '  %<job>s rejected  queue full, retry in %<retry_after>.1fs',
      job: job,
      retry_after: admission.retry_after
    )
  end
end

puts 'Worker'
worker = Thread.new do
  until queue.size(key).zero?
    sleep(queue.next_release_in(key))
    job = queue.dequeue(key)
    puts "  #{elapsed.call}  processing #{job}" if job
  end
end
worker.join
