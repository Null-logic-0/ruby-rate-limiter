# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateLimiter
  module Algorithms
    # Counts each consumer's requests in fixed windows aligned to the clock
    # (a 60-second window runs 17:47:00-17:47:59). Once a consumer reaches
    # `limit` in a window, further requests are rejected until the next one.
    class FixedWindowCounter
      attr_reader :limit, :window

      def initialize(limit:, window:, clock: Clock::Wall)
        Validators::ConfigurationValidator.validate!(
          limit: [limit, :integer],
          window: [window, :number]
        )

        @limit = limit
        @window = window
        @clock = clock
        @window_start = nil
        @counts = Hash.new(0)
        @mutex = Mutex.new
      end

      def acquire(key, cost: 1)
        Validators::CostValidator.validate!(
          cost: cost,
          maximum: @limit,
          type: :integer
        )

        @mutex.synchronize do
          now = @clock.now
          roll_window(now)
          used = @counts[key]
          reset_after = @window_start + @window - now

          if used + cost <= @limit
            @counts[key] = used + cost
            Result.new(allowed: true, remaining: @limit - used - cost, retry_after: 0.0, reset_after:)
          else
            Result.new(allowed: false, remaining: @limit - used, retry_after: reset_after, reset_after:)
          end
        end
      end

      # Requests counted for a consumer in the current window.
      def count(key)
        @mutex.synchronize do
          roll_window(@clock.now)
          @counts[key]
        end
      end

      # Number of consumers with a counter in the current window.
      def tracked_keys
        @mutex.synchronize do
          roll_window(@clock.now)
          @counts.size
        end
      end

      private

      # Every consumer shares the same window boundaries, so when a new window
      # starts, every stored count belongs to the past: drop them all at once.
      # If the clock moves backwards, keep counting in the current window
      # rather than handing out a fresh allowance.
      def roll_window(now)
        start = (now / @window).floor * @window
        return if @window_start && start <= @window_start

        @window_start = start
        @counts.clear
      end
    end
  end
end
