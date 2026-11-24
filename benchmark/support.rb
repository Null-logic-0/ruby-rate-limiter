# frozen_string_literal: true

require 'benchmark'
require 'objspace'
require_relative '../lib/rate_limiter'

# Shared pieces for the benchmark scripts. Every workload is deterministic:
# keys come from a seeded Random, time comes from a clock the script steps,
# and each measurement is warmed up, repeated, and reported as the median.
module Bench
  # Sizes, overridable for a quicker or a longer run.
  OPS = Integer(ENV.fetch('BENCH_OPS', '50_000').delete('_'))
  ROUNDS = Integer(ENV.fetch('BENCH_ROUNDS', '5'))
  CLIENTS = Integer(ENV.fetch('BENCH_CLIENTS', '1_000').delete('_'))
  # Each Redis decision is a network round trip (~50x slower), so the Redis
  # rows run a tenth of the operations; per-operation figures stay comparable.
  REDIS_OPS = [OPS / 10, 1_000].max
  LIMIT = 100
  WINDOW = 60
  SEED = 42

  # Time that moves only when told to, so every run sees the same timeline.
  # A request every 2 ms: 30,000 requests a minute spread over the clients.
  class SteppingClock
    STEP = 0.002

    attr_reader :now

    def initialize(start = 1_000_000.0)
      @now = start
    end

    def tick = @now += STEP
  end

  # A frozen clock, for threads: advancing a shared clock from many threads
  # would itself be a race. Nothing refills, so `limit` is exact.
  class FrozenClock
    def now = 1_000_000.0
  end

  module_function

  def redis_url = ENV.fetch('TEST_REDIS_URL') { ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15') }

  # A Redis client if one answers at redis_url, else nil (and the Redis rows are skipped).
  def redis
    return @redis if defined?(@redis)

    require 'redis'
    @redis = Redis.new(url: redis_url, timeout: 0.5).tap(&:ping)
  rescue LoadError, StandardError
    @redis = nil
  end

  # The same Redis behind a pool of 16 connections (13C), or nil when there is
  # no Redis or connection_pool can't be loaded. It's already in the bundle,
  # through redis-client.
  def pooled_redis
    return @pooled_redis if defined?(@pooled_redis)

    @pooled_redis = redis && begin
      require 'connection_pool'
      ConnectionPool::Wrapper.new(size: 16, timeout: 1) { Redis.new(url: redis_url, timeout: 0.5) }
    rescue LoadError
      nil
    end
  end

  def namespace = "rate_limiter_bench:#{Process.pid}"

  # Deletes every key this benchmark wrote, and nothing else.
  def clean_redis
    redis&.scan_each(match: "#{namespace}:*") { |key| redis.del(key) }
  end

  # Every algorithm to compare: [name, kind, builder(clock)]. Built through
  # the registry, exactly as an application builds them.
  def algorithms
    names = RateLimiter::Registry.names.map { |name| [name, RateLimiter::Registry.fetch(name).kind] }
    list = names.map { |name, kind| [name.to_s, kind, ->(clock) { build(name, clock) }] }
    return list unless redis

    list << ['sliding_window_counter (redis)', :immediate, ->(clock) { build(:sliding_window_counter, clock, redis) }]
  end

  def build(name, clock, redis_client = nil)
    config = RateLimiter::Configuration.new.tap do |c|
      c.algorithm = name
      c.limit = LIMIT
      c.window = WINDOW
      c.clock = clock
      c.redis = redis_client
      c.namespace = namespace
    end
    kind = RateLimiter::Registry.fetch(name).kind
    kind == :queue ? RateLimiter.queue(config) : RateLimiter.limiter(config)
  end

  # The same sequence of client keys for every algorithm and every run.
  def keys(count = OPS, clients: CLIENTS)
    random = Random.new(SEED)
    Array.new(count) { "ip:client-#{random.rand(clients)}" }
  end

  def redis?(name) = name.include?('redis')

  def ops_for(name) = redis?(name) ? REDIS_OPS : OPS

  # One decision: acquire for immediate algorithms; enqueue then dequeue for
  # the queue, since a queue only does its job when both happen.
  def decide(limiter, kind, key)
    if kind == :queue
      limiter.enqueue(key, :job)
      limiter.dequeue(key)
    else
      limiter.acquire(key)
    end
  end

  # Runs the block once to warm up, then ROUNDS times, and returns the median
  # of whatever it returns (a number, or an Array of numbers compared by its
  # first element).
  def median_of_rounds
    yield
    results = Array.new(ROUNDS) { yield }
    results.sort_by { |result| Array(result).first }[ROUNDS / 2]
  end

  def median(values) = values.sort[values.size / 2]

  # A plain-text table: first column left-aligned, the rest right-aligned.
  def table(headers, rows)
    all = [headers, *rows].map { |row| row.map(&:to_s) }
    widths = headers.each_index.map { |i| all.map { |row| row[i].size }.max }
    line = lambda do |cells|
      cells.each_with_index.map { |cell, i| i.zero? ? cell.ljust(widths[i]) : cell.rjust(widths[i]) }.join('  ')
    end
    [line.call(all.first), widths.map { |width| '-' * width }.join('  '), *all.drop(1).map(&line)].join("\n")
  end

  def number(value) = value.round.to_s.reverse.scan(/\d{1,3}/).join(',').reverse

  def banner(title)
    yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'YJIT on' : 'YJIT off'
    puts "#{title}\n#{RUBY_DESCRIPTION} (#{yjit})"
    puts "ops per round: #{number(OPS)}, rounds: #{ROUNDS} (median reported), clients: #{number(CLIENTS)}, " \
         "limit: #{LIMIT} per #{WINDOW} s"
    puts "Redis: #{redis ? redis_url : 'not reachable, Redis row skipped'}\n\n"
  end
end
