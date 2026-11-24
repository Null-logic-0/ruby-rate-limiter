# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateGuard
  module Algorithms
    # Estimates a sliding window from two fixed-window counters per key.
    class SlidingWindowCounter
      # Room for float rounding.
      EPSILON = 1e-9

      # index = window number: floor(time / window)
      State = Struct.new(:index, :current, :previous)

      attr_reader :limit, :window

      def initialize(limit:, window:, clock: Clock::Wall)
        Validators::ConfigurationValidator.validate!(
          limit: [limit, :integer],
          window: [window, :number]
        )

        @limit = limit
        @window = window
        @clock = clock
        @states = {}
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
          state = (@states[key] ||= State.new(window_index(now), 0, 0))
          advance(state, now)
          estimated = estimate_for(state, now)

          if estimated + cost + reserve <= @limit + EPSILON
            state.current += cost
            Result.new(allowed: true, remaining: remaining(estimated + cost), retry_after: 0.0,
                       reset_after: reset_after(state, now))
          else
            Result.new(allowed: false, remaining: remaining(estimated),
                       retry_after: retry_after(state, now, cost + reserve), reset_after: reset_after(state, now))
          end
        end
      end

      # Estimated request count for a key right now.
      def estimate(key)
        @mutex.synchronize do
          state = @states[key]
          next 0.0 if state.nil?

          now = @clock.now
          advance(state, now)
          estimate_for(state, now)
        end
      end

      # Number of keys stored.
      def tracked_keys
        @mutex.synchronize { @states.size }
      end

      # Deletes keys whose counts have expired. Returns how many.
      def prune
        @mutex.synchronize do
          now = @clock.now
          before = @states.size
          @states.delete_if do |_key, state|
            advance(state, now)
            state.current.zero? && state.previous.zero?
          end
          before - @states.size
        end
      end

      private

      def window_index(time)
        (time / @window).floor
      end

      def window_start(state)
        state.index * @window
      end

      # Move a key's counters to the current window (compares integers, not floats).
      def advance(state, now)
        index = window_index(now)
        return if index <= state.index # same window, or the clock moved backwards

        state.previous = index == state.index + 1 ? state.current : 0
        state.current = 0
        state.index = index
      end

      def estimate_for(state, now)
        progress = ((now - window_start(state)) / @window).clamp(0.0, 1.0)
        (state.previous * (1 - progress)) + state.current
      end

      def remaining(estimated)
        [(@limit - estimated + EPSILON).floor, 0].max
      end

      # Seconds until `cost` more fits.
      def retry_after(state, now, cost)
        room = @limit - state.current - cost

        if room >= 0
          # Wait until the previous window's weight shrinks enough.
          progress = 1 - room.fdiv(state.previous)
          window_start(state) + (progress * @window) - now
        else
          # The current window alone is too full: wait into the next one.
          progress = 1 - (@limit - cost).fdiv(state.current)
          window_start(state) + @window + (progress * @window) - now
        end
      end

      # Seconds until the estimate is zero.
      def reset_after(state, now)
        start = window_start(state)

        if state.current.positive?
          start + (2 * @window) - now
        elsif state.previous.positive?
          start + @window - now
        else
          0.0
        end
      end
    end
  end
end
