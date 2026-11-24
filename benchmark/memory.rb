# frozen_string_literal: true

# State kept per client: memory before and after 10,000 clients make 20
# requests each, divided by 10,000. The clock is frozen, so every client's
# state is still live when it is measured (a moving clock would let windows
# roll over and expire part of it). In-memory algorithms are measured with
# ObjectSpace.memsize_of_all after a full GC; the Redis counter with Redis's
# own MEMORY USAGE. Every limiter is kept alive until the end, so freeing one
# can't make the next look smaller.
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

    # Redis stores the state, so ask Redis; a sample of 200 keys is plenty,
    # since every client's hash has the same shape.
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
