# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'

module RateLimiter
  module Algorithms
    # Each consumer has a bucket holding up to `capacity` tokens. Tokens are
    # added continuously at `refill_rate` per second. A request spends `cost`
    # tokens, or is rejected if the bucket holds fewer than that.
    class TokenBucket
      # Float arithmetic drifts: adding 0.1 ten times gives 0.9999999999999999.
      # A balance within EPSILON of the cost counts as enough.
      EPSILON = 1e-9

      State = Struct.new(:tokens, :updated_at)

      attr_reader :capacity, :refill_rate

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

      def acquire(key, cost: 1)
        validate_cost!(cost)

        @mutex.synchronize do
          state = refill(key)

          if state.tokens + EPSILON >= cost
            state.tokens = [state.tokens - cost, 0.0].max
            Result.new(allowed: true, remaining: whole_tokens(state), retry_after: 0.0)
          else
            retry_after = (cost - state.tokens) / @refill_rate
            Result.new(allowed: false, remaining: whole_tokens(state), retry_after: retry_after)
          end
        end
      end

      # Current balance for a consumer, after refilling. Useful for tests and metrics.
      def tokens(key)
        @mutex.synchronize { refill(key).tokens }
      end

      private

      # Lazy refill: instead of a timer adding tokens, we add everything that
      # accrued since the last visit, capped at capacity.
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

      def validate_cost!(cost)
        raise ArgumentError, 'cost must be a positive number' unless Utils::NumericUtils.positive_number?(cost)
        raise ArgumentError, "cost #{cost} exceeds capacity #{@capacity}" if cost > @capacity
      end
    end
  end
end
