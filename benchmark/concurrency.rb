# frozen_string_literal: true

# Threads sharing one limiter:
# 1. Speed with 1, 4 and 16 threads. The GVL limits CPU-bound code;
#    threads help only while waiting on I/O (Redis).
# 2. Correctness: 16 threads hit one client at once. Never more than the limit.
#
#   bundle exec ruby benchmark/concurrency.rb

require_relative 'support'

module Bench
  module Concurrency
    THREADS = [1, 4, 16].freeze
    ATTEMPTS_PER_THREAD = 50

    module_function

    # { name => { throughput: { 1 => ops/s, ... }, admitted:, exact: } }
    def run
      results = candidates.to_h do |name, kind, builder|
        keys = Bench.keys(Bench.ops_for(name))
        throughput = THREADS.to_h do |threads|
          [threads, Bench.median_of_rounds { measure(builder.call(FrozenClock.new), kind, keys, threads) }]
        end
        admitted = hot_key_admissions(builder.call(FrozenClock.new), kind)
        Bench.clean_redis

        [name, { throughput:, admitted:, exact: admitted == Bench::LIMIT }]
      end
      Bench.clean_redis
      results
    end

    # Every algorithm, plus Redis with a connection pool.
    def candidates
      list = Bench.algorithms
      return list unless Bench.pooled_redis

      list + [['sliding_window_counter (redis, pool of 16)', :immediate,
               ->(clock) { Bench.build(:sliding_window_counter, clock, Bench.pooled_redis) }]]
    end

    # Decisions per second with `threads` threads.
    def measure(limiter, kind, keys, threads)
      Bench.clean_redis
      slices = keys.each_slice((keys.size / threads.to_f).ceil).to_a
      elapsed = run_together(slices.size) { |i| slices[i].each { |key| Bench.decide(limiter, kind, key) } }

      keys.size / elapsed
    end

    # 16 threads x 50 tries on one client, limit 100.
    def hot_key_admissions(limiter, kind)
      Bench.clean_redis
      admitted = Queue.new
      run_together(16) do
        ATTEMPTS_PER_THREAD.times do
          ok = kind == :queue ? limiter.enqueue('ip:hot', :job).accepted? : limiter.acquire('ip:hot').allowed?
          admitted << true if ok
        end
      end

      admitted.size
    end

    # Starts all threads together; returns elapsed time.
    def run_together(count, &work)
      start = Queue.new
      threads = Array.new(count) do |i|
        Thread.new do
          start.pop
          work.call(i)
        end
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      count.times { start << :go }
      threads.each(&:join)

      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def print(results)
      rows = results.map do |name, r|
        [name, *THREADS.map { |t| Bench.number(r[:throughput][t]) }, "#{r[:admitted]}/#{Bench::LIMIT}",
         r[:exact] ? 'yes' : 'NO']
      end
      puts Bench.table(['algorithm', *THREADS.map { |t| "#{t} thread#{'s' if t > 1}/s" }, 'admitted', 'exact'], rows)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Bench.banner('Concurrency: throughput by thread count, and exactness under contention')
  Bench::Concurrency.print(Bench::Concurrency.run)
end
