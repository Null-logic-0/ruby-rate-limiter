# frozen_string_literal: true

# Single-thread speed: decisions per second, wall time and CPU time per
# decision. The clock moves 2 ms per request, so buckets refill and windows
# roll over as they would under steady traffic.
#
#   bundle exec ruby benchmark/single_thread.rb

require_relative 'support'

module Bench
  module SingleThread
    module_function

    # { name => { ops_per_sec:, us_per_op:, cpu_us_per_op: } }
    def run
      Bench.algorithms.to_h do |name, kind, builder|
        keys = Bench.keys(Bench.ops_for(name))
        ops_per_sec, cpu_per_op = Bench.median_of_rounds do
          Bench.clean_redis
          clock = SteppingClock.new
          limiter = builder.call(clock)
          tms = Benchmark.measure do
            keys.each do |key|
              clock.tick
              Bench.decide(limiter, kind, key)
            end
          end
          [keys.size / tms.real, tms.total / keys.size]
        end
        Bench.clean_redis

        [name, { ops_per_sec:, us_per_op: 1e6 / ops_per_sec, cpu_us_per_op: cpu_per_op * 1e6 }]
      end
    end

    def print(results)
      rows = results.map do |name, r|
        [name, Bench.number(r[:ops_per_sec]), format('%.2f', r[:us_per_op]), format('%.2f', r[:cpu_us_per_op])]
      end
      puts Bench.table(['algorithm', 'decisions/s', 'µs/decision', 'CPU µs/decision'], rows)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Bench.banner('Single-thread throughput')
  Bench::SingleThread.print(Bench::SingleThread.run)
end
