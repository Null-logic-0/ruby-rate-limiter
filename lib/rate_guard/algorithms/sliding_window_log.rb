# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateGuard
  module Algorithms
    # Stores each request's time and allows a new one only if the last
    # `window` seconds have room. Exact, but keeps up to `limit` times per key.
    class SlidingWindowLog
      attr_reader :limit, :window

      def initialize(limit:, window:, clock: Clock::Monotonic)
        Validators::ConfigurationValidator.validate!(
          limit: [limit, :integer],
          window: [window, :number]
        )

        @limit = limit
        @window = window
        @clock = clock
        @logs = {}
        @mutex = Mutex.new
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

        @mutex.synchronize do
          log = (@logs[key] ||= [])
          now = current_time(log)
          expire(log, now)

          if log.size + cost + reserve <= @limit
            log.concat(Array.new(cost, now))
            Result.new(allowed: true, remaining: @limit - log.size, retry_after: 0.0,
                       reset_after: reset_after(log, now))
          else
            # It fits once enough of the oldest entries expire.
            must_expire = log[log.size + cost + reserve - @limit - 1]
            Result.new(allowed: false, remaining: @limit - log.size, retry_after: must_expire + @window - now,
                       reset_after: reset_after(log, now))
          end
        end
      end

      # Requests logged for a key in the last `window` seconds.
      def count(key)
        @mutex.synchronize do
          log = @logs[key]
          next 0 if log.nil?

          expire(log, current_time(log))
          log.size
        end
      end

      # Number of keys with a log.
      def tracked_keys
        @mutex.synchronize { @logs.size }
      end

      # Deletes fully expired logs. Returns how many.
      # Run it now and then, or keys that never return stay forever.
      def prune
        @mutex.synchronize do
          before = @logs.size
          @logs.delete_if do |_key, log|
            expire(log, current_time(log))
            log.empty?
          end
          before - @logs.size
        end
      end

      private

      # Appending keeps the log sorted. If the clock goes back, reuse the
      # newest time so the order stays correct.
      def current_time(log)
        now = @clock.now
        log.empty? ? now : [now, log.last].max
      end

      # Old entries are at the front; binary search finds where they end.
      def expire(log, now)
        first_live = log.bsearch_index { |time| time + @window > now } || log.size
        log.shift(first_live)
      end

      def reset_after(log, now)
        log.empty? ? 0.0 : log.last + @window - now
      end
    end
  end
end
