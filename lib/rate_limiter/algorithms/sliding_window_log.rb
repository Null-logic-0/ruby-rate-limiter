# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateLimiter
  module Algorithms
    # Keeps a log of when each consumer's recent requests were admitted, and
    # admits a new request only if the requests logged in the last `window`
    # seconds leave room for it. Exact at every moment, but stores up to
    # `limit` timestamps per consumer.
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

      def acquire(key, cost: 1)
        Validators::CostValidator.validate!(
          cost: cost,
          maximum: @limit,
          type: :integer
        )

        @mutex.synchronize do
          log = (@logs[key] ||= [])
          now = current_time(log)
          expire(log, now)

          if log.size + cost <= @limit
            log.concat(Array.new(cost, now))
            Result.new(allowed: true, remaining: @limit - log.size, retry_after: 0.0,
                       reset_after: reset_after(log, now))
          else
            # The request fits once enough of the oldest entries have expired.
            must_expire = log[log.size + cost - @limit - 1]
            Result.new(allowed: false, remaining: @limit - log.size, retry_after: must_expire + @window - now,
                       reset_after: reset_after(log, now))
          end
        end
      end

      # Requests logged for a consumer in the last `window` seconds.
      def count(key)
        @mutex.synchronize do
          log = @logs[key]
          next 0 if log.nil?

          expire(log, current_time(log))
          log.size
        end
      end

      # Number of consumers that currently have a log.
      def tracked_keys
        @mutex.synchronize { @logs.size }
      end

      # Deletes logs whose entries have all expired. Returns how many were
      # removed. Run it periodically: consumers that never come back would
      # otherwise keep their log forever.
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

      # Timestamps are appended in order, so the log stays sorted without any
      # sorting. If the clock ever reads earlier than the newest entry, use
      # the newest entry's time instead, so the order is never broken.
      def current_time(log)
        now = @clock.now
        log.empty? ? now : [now, log.last].max
      end

      # Entries older than `window` seconds sit at the front of the sorted log.
      # Binary search finds the first live entry everything before it goes.
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
