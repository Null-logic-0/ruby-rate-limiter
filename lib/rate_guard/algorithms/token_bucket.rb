# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateGuard
  module Algorithms
    # Each key has up to `capacity` tokens, refilled at `refill_rate`
    # per second. A request spends `cost` tokens or is rejected.
    class TokenBucket
      # Float math drifts (0.1 * 10 = 0.9999999999999999). Close enough counts.
      EPSILON = 1e-9

      State = Struct.new(:tokens, :updated_at)

      attr_reader :capacity, :refill_rate

      # The burst the bucket can take. All limiters answer #limit.
      alias limit capacity

      def initialize(capacity:, refill_rate:, clock: Clock::Monotonic)
        Validators::ConfigurationValidator.validate!(
          capacity: [capacity, :integer],
          refill_rate: [refill_rate, :number]
        )

        @capacity = capacity
        @refill_rate = refill_rate
        @clock = clock
        @buckets = {}
        @mutex = Mutex.new
      end

      # Allows the request and spends `cost` if there is room.
      # reserve: extra units that must stay free (for others); only cost is spent.
      def acquire(key, cost: 1, reserve: 0)
        Validators::CostValidator.validate!(
          cost: cost,
          maximum: @capacity,
          maximum_name: 'capacity',
          type: :number,
          reserve: reserve
        )

        @mutex.synchronize do
          state = refill(key)

          if state.tokens + EPSILON >= cost + reserve
            state.tokens = [state.tokens - cost, 0.0].max
            Result.new(allowed: true, remaining: whole_tokens(state), retry_after: 0.0,
                       reset_after: until_full(state))
          else
            retry_after = (cost + reserve - state.tokens) / @refill_rate
            Result.new(allowed: false, remaining: whole_tokens(state), retry_after: retry_after,
                       reset_after: until_full(state))
          end
        end
      end

      # Current tokens for a key, after refilling.
      def tokens(key)
        @mutex.synchronize { refill(key).tokens }
      end

      private

      # Add the tokens earned since the last request, up to capacity.
      def refill(key)
        now = @clock.now
        state = (@buckets[key] ||= State.new(@capacity.to_f, now))

        elapsed = now - state.updated_at
        if elapsed.positive?
          state.tokens = [state.tokens + (elapsed * @refill_rate), @capacity].min.to_f
          state.updated_at = now
        end

        state
      end

      def whole_tokens(state)
        (state.tokens + EPSILON).floor
      end

      # Seconds until the bucket is full again.
      def until_full(state)
        (@capacity - state.tokens) / @refill_rate
      end
    end
  end
end
