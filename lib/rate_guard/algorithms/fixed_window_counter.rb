# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateGuard
  module Algorithms
    # Counts requests per clock-aligned window (e.g. 17:47:00-17:47:59).
    # At `limit`, requests are rejected until the next window.
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
          now = @clock.now
          roll_window(now)
          used = @counts[key]
          reset_after = @window_start + @window - now

          if used + cost + reserve <= @limit
            @counts[key] = used + cost
            Result.new(allowed: true, remaining: @limit - used - cost, retry_after: 0.0, reset_after:)
          else
            Result.new(allowed: false, remaining: @limit - used, retry_after: reset_after, reset_after:)
          end
        end
      end

      # Requests counted for a key in the current window.
      def count(key)
        @mutex.synchronize do
          roll_window(@clock.now)
          @counts[key]
        end
      end

      # Number of keys counted in the current window.
      def tracked_keys
        @mutex.synchronize do
          roll_window(@clock.now)
          @counts.size
        end
      end

      private

      # A new window makes all stored counts old, so drop them together.
      # If the clock goes back, keep the current window.
      def roll_window(now)
        start = (now / @window).floor * @window
        return if @window_start && start <= @window_start

        @window_start = start
        @counts.clear
      end
    end
  end
end
