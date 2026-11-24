# frozen_string_literal: true

require 'digest'
require 'redis'
require_relative '../result'

module RateLimiter
  module Algorithms
    # The sliding window counter (see SlidingWindowCounter) with its state in
    # Redis, so every application server shares one count per consumer. The
    # read-decide-write step runs as one Lua script, which Redis executes
    # atomically: no other command can run in between.
    class RedisSlidingWindowCounter
      SCRIPT = File.read(File.expand_path('sliding_window_counter.lua', __dir__)).freeze
      SCRIPT_SHA = Digest::SHA1.hexdigest(SCRIPT).freeze

      FAILURE_POLICIES = %i[allow reject].freeze

      # When failing closed, how long rejected clients are told to wait.
      FAIL_CLOSED_RETRY_AFTER = 1.0

      EPSILON = 1e-9

      attr_reader :limit, :window, :failure_policy

      # redis          - a Redis client (redis-rb), shared by every request
      # failure_policy - :allow (fail open) or :reject (fail closed) when Redis
      #                  cannot be reached
      # on_error       - optional callable, given the exception when that happens
      # clock          - optional; by default the Redis server's clock is used,
      #                  so all application servers agree on the window
      def initialize(redis:, limit:, window:, namespace: 'rate_limiter', failure_policy: :allow,
                     on_error: nil, clock: nil)
        raise ArgumentError, 'redis must respond to #evalsha and #eval' unless redis_client?(redis)
        raise ArgumentError, 'limit must be a positive integer' unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, 'window must be a positive number' unless Utils::NumericUtils.positive_number?(window)
        unless FAILURE_POLICIES.include?(failure_policy)
          raise ArgumentError, "failure_policy must be one of #{FAILURE_POLICIES.inspect}"
        end

        @redis = redis
        @limit = limit
        @window = window
        @prefix = "#{namespace}:w#{window.to_i == window ? window.to_i : window}"
        @failure_policy = failure_policy
        @on_error = on_error
        @clock = clock
      end

      # Admits the request if `cost` units are available and spends them.
      # reserve: units this request may not use (they are kept for others),
      # so it is admitted only while cost + reserve units are available. Only
      # `cost` is spent. The check and the spend happen in one step.
      def acquire(key, cost: 1, reserve: 0)
        Validators::CostValidator.validate!(
          cost: cost,
          maximum: @limit,
          type: :integer,
          reserve: reserve
        )

        reply = run_script(redis_key(key), [@limit, @window, cost, @clock ? @clock.now : '', reserve])
        to_result(reply, cost + reserve)
      rescue Redis::BaseConnectionError => e
        @on_error&.call(e)
        failure_result
      end

      # The Redis key holding a consumer's counters, e.g.
      # "rate_limiter:w60:ip:203.0.113.7". The window is part of the key, so
      # changing it never reinterprets counters written under the old one.
      def redis_key(key)
        "#{@prefix}:#{key}"
      end

      private

      # EVALSHA sends only the script's 40-character hash. If Redis has
      # forgotten the script (restart, failover, SCRIPT FLUSH), it answers
      # NOSCRIPT, and EVAL sends the full source once, which caches it again.
      def run_script(key, argv)
        @redis.evalsha(SCRIPT_SHA, keys: [key], argv: argv)
      rescue Redis::CommandError => e
        raise unless e.message.start_with?('NOSCRIPT')

        @redis.eval(SCRIPT, keys: [key], argv: argv)
      end

      # needed: cost + reserve, the units that had to be available.
      def to_result(reply, needed)
        allowed, estimate, current, previous, index, now = reply
        estimate = Float(estimate)
        now = Float(now)
        window_start = index * @window
        reset_after = reset_after(window_start, current, previous, now)

        if allowed == 1
          Result.new(allowed: true, remaining: remaining(estimate), retry_after: 0.0, reset_after:)
        else
          retry_after = retry_after(window_start, current, previous, now, needed)
          Result.new(allowed: false, remaining: remaining(estimate), retry_after:, reset_after:)
        end
      end

      # Fail open: let traffic through unlimited, rather than take the whole
      # API down with Redis. Fail closed: protect the backend at all costs.
      def failure_result
        if @failure_policy == :allow
          Result.new(allowed: true, remaining: @limit, retry_after: 0.0)
        else
          Result.new(allowed: false, remaining: 0, retry_after: FAIL_CLOSED_RETRY_AFTER)
        end
      end

      def remaining(estimated)
        [(@limit - estimated + EPSILON).floor, 0].max
      end

      def retry_after(window_start, current, previous, now, cost)
        room = @limit - current - cost

        if room >= 0
          progress = 1 - room.fdiv(previous)
          window_start + (progress * @window) - now
        else
          progress = 1 - (@limit - cost).fdiv(current)
          window_start + @window + (progress * @window) - now
        end
      end

      def reset_after(window_start, current, previous, now)
        if current.positive?
          window_start + (2 * @window) - now
        elsif previous.positive?
          window_start + @window - now
        else
          0.0
        end
      end

      def redis_client?(redis)
        redis.respond_to?(:evalsha) && redis.respond_to?(:eval)
      end
    end
  end
end
