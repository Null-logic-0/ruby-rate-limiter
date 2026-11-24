# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateLimiter
  module Algorithms
    # Approximates a sliding window with two fixed-window counters per consumer.
    class SlidingWindowCounter
      # Weighted counts are fractional, so allow for float rounding.
      EPSILON = 1e-9

      # index is the window number: floor(time / window).
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

      # The weighted request count for a consumer right now.
      def estimate(key)
        @mutex.synchronize do
          state = @states[key]
          next 0.0 if state.nil?

          now = @clock.now
          advance(state, now)
          estimate_for(state, now)
        end
      end

      # Number of consumers with stored counters.
      def tracked_keys
        @mutex.synchronize { @states.size }
      end

      # Deletes consumers whose counters have both aged out. Returns how many
      # were removed.
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

      # Moves a consumer's counters forward to the window containing `now`.
      # Comparing integer window numbers avoids float equality problems.
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

      # How long until `cost` more requests would fit under the limit.
      def retry_after(state, now, cost)
        room = @limit - state.current - cost

        if room >= 0
          # Wait for the previous window's weight to shrink until
          # previous * (1 - progress) == room.
          progress = 1 - room.fdiv(state.previous)
          window_start(state) + (progress * @window) - now
        else
          # The current window alone is too full. In the next window this
          # count becomes "previous" and must decay until it leaves room.
          progress = 1 - (@limit - cost).fdiv(state.current)
          window_start(state) + @window + (progress * @window) - now
        end
      end

      # Seconds until both counters have aged out and the estimate is zero.
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
