# frozen_string_literal: true

require 'digest'
require 'redis'
require_relative '../result'

module RateGuard
  module Algorithms
    # SlidingWindowCounter stored in Redis, shared by all servers.
    # Each decision is one Lua script, which Redis runs atomically.
    class RedisSlidingWindowCounter
      SCRIPT = File.read(File.expand_path('sliding_window_counter.lua', __dir__)).freeze
      SCRIPT_SHA = Digest::SHA1.hexdigest(SCRIPT).freeze

      FAILURE_POLICIES = %i[allow reject].freeze

      # Retry-after sent when failing closed.
      FAIL_CLOSED_RETRY_AFTER = 1.0

      EPSILON = 1e-9

      attr_reader :limit, :window, :failure_policy

      # redis          - a Redis client
      # failure_policy - :allow (fail open) or :reject (fail closed) if Redis is down
      # on_error       - optional callable, given the error
      # clock          - optional; defaults to the Redis server's clock
      def initialize(redis:, limit:, window:, namespace: 'rate_guard', failure_policy: :allow,
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

      # Allows the request and spends `cost` if there is room.
      # reserve: extra units that must stay free (for others); only cost is spent.
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

      # e.g. "rate_guard:w60:ip:203.0.113.7". The window is in the key,
      # so changing it never reuses old counters.
      def redis_key(key)
        "#{@prefix}:#{key}"
      end

      private

      # EVALSHA sends only the script's hash. If Redis lost the script
      # (NOSCRIPT), EVAL sends it once and Redis caches it again.
      def run_script(key, argv)
        @redis.evalsha(SCRIPT_SHA, keys: [key], argv: argv)
      rescue Redis::CommandError => e
        raise unless e.message.start_with?('NOSCRIPT')

        @redis.eval(SCRIPT, keys: [key], argv: argv)
      end

      # needed = cost + reserve
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

      # Fail open: allow everything. Fail closed: reject everything.
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
