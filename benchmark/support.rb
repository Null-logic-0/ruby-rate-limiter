# frozen_string_literal: true

require 'benchmark'
require 'objspace'
require_relative '../lib/rate_guard'

# Shared benchmark helpers. Same keys and timeline every run;
# each result is the median of several rounds.
module Bench
  # Sizes; override with ENV.
  OPS = Integer(ENV.fetch('BENCH_OPS', '50_000').delete('_'))
  ROUNDS = Integer(ENV.fetch('BENCH_ROUNDS', '5'))
  CLIENTS = Integer(ENV.fetch('BENCH_CLIENTS', '1_000').delete('_'))
  # Redis is much slower, so its rows do a tenth of the work.
  REDIS_OPS = [OPS / 10, 1_000].max
  LIMIT = 100
  WINDOW = 60
  SEED = 42

  # A clock moved by hand: 2 ms per request.
  class SteppingClock
    STEP = 0.002

    attr_reader :now

    def initialize(start = 1_000_000.0)
      @now = start
    end

    def tick = @now += STEP
  end

  # A clock that never moves, safe to share between threads.
  class FrozenClock
    def now = 1_000_000.0
  end

  module_function

  def redis_url = ENV.fetch('TEST_REDIS_URL') { ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15') }

  # A Redis client, or nil if none is running (Redis rows are skipped).
  def redis
    return @redis if defined?(@redis)

    require 'redis'
    @redis = Redis.new(url: redis_url, timeout: 0.5).tap(&:ping)
  rescue LoadError, StandardError
    @redis = nil
  end

  # Redis with a pool of 16 connections, or nil.
  def pooled_redis
    return @pooled_redis if defined?(@pooled_redis)

    @pooled_redis = redis && begin
      require 'connection_pool'
      ConnectionPool::Wrapper.new(size: 16, timeout: 1) { Redis.new(url: redis_url, timeout: 0.5) }
    rescue LoadError
      nil
    end
  end

  def namespace = "rate_guard_bench:#{Process.pid}"

  # Deletes only this benchmark's keys.
  def clean_redis
    redis&.scan_each(match: "#{namespace}:*") { |key| redis.del(key) }
  end

  # [name, kind, builder(clock)] for each algorithm, built via the registry.
  def algorithms
    names = RateGuard::Registry.names.map { |name| [name, RateGuard::Registry.fetch(name).kind] }
    list = names.map { |name, kind| [name.to_s, kind, ->(clock) { build(name, clock) }] }
    return list unless redis

    list << ['sliding_window_counter (redis)', :immediate, ->(clock) { build(:sliding_window_counter, clock, redis) }]
  end

  def build(name, clock, redis_client = nil)
    config = RateGuard::Configuration.new.tap do |c|
      c.algorithm = name
      c.limit = LIMIT
      c.window = WINDOW
      c.clock = clock
      c.redis = redis_client
      c.namespace = namespace
    end
    kind = RateGuard::Registry.fetch(name).kind
    kind == :queue ? RateGuard.queue(config) : RateGuard.limiter(config)
  end

  # The same client keys every run.
  def keys(count = OPS, clients: CLIENTS)
    random = Random.new(SEED)
    Array.new(count) { "ip:client-#{random.rand(clients)}" }
  end

  def redis?(name) = name.include?('redis')

  def ops_for(name) = redis?(name) ? REDIS_OPS : OPS

  # One decision: acquire, or enqueue + dequeue for the queue.
  def decide(limiter, kind, key)
    if kind == :queue
      limiter.enqueue(key, :job)
      limiter.dequeue(key)
    else
      limiter.acquire(key)
    end
  end

  # Warm up once, run ROUNDS times, return the median.
  def median_of_rounds
    yield
    results = Array.new(ROUNDS) { yield }
    results.sort_by { |result| Array(result).first }[ROUNDS / 2]
  end

  def median(values) = values.sort[values.size / 2]

  # A plain-text table.
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
