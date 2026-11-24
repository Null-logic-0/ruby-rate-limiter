# frozen_string_literal: true

require_relative '../clock'
require_relative '../result'
require_relative '../validators/configuration_validator'
require_relative '../validators/cost_validator'

module RateGuard
  module Algorithms
    # Each key has a bucket of `capacity`. Requests pour in `cost`;
    # it drains at `leak_rate` per second. Overflow is rejected.
    class LeakyBucketMeter
      EPSILON = 1e-9

      State = Struct.new(:level, :updated_at)

      attr_reader :capacity, :leak_rate

      # The burst the bucket can take. All limiters answer #limit.
      alias limit capacity

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
          state = leak(key)

          if state.level + cost + reserve <= @capacity + EPSILON
            state.level = [state.level + cost, @capacity].min.to_f
            Result.new(allowed: true, remaining: headroom(state), retry_after: 0.0,
                       reset_after: until_empty(state))
          else
            retry_after = (state.level + cost + reserve - @capacity) / @leak_rate
            Result.new(allowed: false, remaining: headroom(state), retry_after: retry_after,
                       reset_after: until_empty(state))
          end
        end
      end

      # Current level for a key, after draining.
      def level(key)
        @mutex.synchronize { leak(key).level }
      end

      private

      # Drain everything that leaked since the last request.
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

      # Requests that still fit.
      def headroom(state)
        (@capacity - state.level + EPSILON).floor
      end

      # Seconds until the bucket is empty again.
      def until_empty(state)
        state.level / @leak_rate
      end
    end
  end
end
