# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateLimiter
  module Algorithms
    # Each consumer has a bucket that holds up to `capacity` units of water.
    # Every request pours in `cost` units, and the bucket leaks continuously at
    # `leak_rate` units per second. A request that would overflow is rejected.
    class LeakyBucketMeter
      EPSILON = 1e-9

      State = Struct.new(:level, :updated_at)

      attr_reader :capacity, :leak_rate

      def initialize(capacity:, leak_rate:, clock: Clock::Monotonic)
        Validators::ConfigurationValidator.validate!(
          capacity: [capacity, :integer],
          leak_rate: [leak_rate, :number]
        )

        @capacity = capacity
        @leak_rate = leak_rate
        @clock = clock
        @buckets = {}
        @mutex = Mutex.new
      end

      def acquire(key, cost: 1)
        Validators::CostValidator.validate!(
          cost: cost,
          maximum: @capacity,
          maximum_name: 'capacity',
          type: :number
        )

        @mutex.synchronize do
          state = leak(key)

          if state.level + cost <= @capacity + EPSILON
            state.level = [state.level + cost, @capacity].min.to_f
            Result.new(allowed: true, remaining: headroom(state), retry_after: 0.0)
          else
            retry_after = (state.level + cost - @capacity) / @leak_rate
            Result.new(allowed: false, remaining: headroom(state), retry_after: retry_after)
          end
        end
      end

      # Current water level for a consumer, after leaking.
      def level(key)
        @mutex.synchronize { leak(key).level }
      end

      private

      # Lazy leak: remove all the water that drained since the last visit,
      def leak(key)
        now = @clock.now
        state = (@buckets[key] ||= State.new(0.0, now))

        elapsed = now - state.updated_at
        if elapsed.positive?
          state.level = [state.level - (elapsed * @leak_rate), 0.0].max
          state.updated_at = now
        end

        state
      end

      # Whole requests (of cost 1) that still fit before the bucket overflows.
      def headroom(state)
        (@capacity - state.level + EPSILON).floor
      end
    end
  end
end
