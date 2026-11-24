# frozen_string_literal: true

# Memory per client: 10,000 clients x 20 requests, frozen clock.
# Ruby heap via ObjectSpace; Redis via MEMORY USAGE.
#
#   bundle exec ruby benchmark/memory.rb

require_relative 'support'

module Bench
  module Memory
    CLIENTS = Integer(ENV.fetch('BENCH_MEMORY_CLIENTS', '10_000').delete('_'))
    REQUESTS = 20

    module_function

    # { name => bytes per client }
    def run
      kept_alive = []
      results = Bench.algorithms.to_h do |name, kind, builder|
        bytes = Bench.median_of_rounds do
          Bench.clean_redis
          Bench.redis?(name) ? in_redis(builder) : in_memory(builder, kind, kept_alive)
        end
        [name, bytes]
      end
      Bench.clean_redis
      kept_alive.clear
      results
    end

    def in_memory(builder, kind, kept_alive)
      clock = FrozenClock.new
      full_gc
      before = ObjectSpace.memsize_of_all
      limiter = builder.call(clock)
      kept_alive << limiter
      load_clients(limiter, kind, clock)
      full_gc

      (ObjectSpace.memsize_of_all - before).fdiv(CLIENTS)
    end

    # Ask Redis. 200 sample keys is enough: all have the same shape.
    def in_redis(builder)
      clock = FrozenClock.new
      limiter = builder.call(clock)
      load_clients(limiter, :immediate, clock, clients: 200)
      sizes = 200.times.map { |c| Bench.redis.call('MEMORY', 'USAGE', limiter.redis_key("ip:client-#{c}")).to_i }

      sizes.sum.fdiv(sizes.size)
    end

    def load_clients(limiter, kind, _clock, clients: CLIENTS)
      clients.times do |c|
        key = "ip:client-#{c}"
        REQUESTS.times { Bench.decide(limiter, kind, key) }
      end
    end

    def full_gc
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
    end

    def print(results)
      rows = results.map { |name, bytes| [name, Bench.number(bytes), Bench.number(bytes * 1_000_000 / 1024**2)] }
      puts Bench.table(['algorithm', 'bytes/client', 'MB per million clients'], rows)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Bench.banner("State size per client (#{Bench.number(Bench::Memory::CLIENTS)} clients, " \
               "#{Bench::Memory::REQUESTS} requests each)")
  Bench::Memory.print(Bench::Memory.run)
end
