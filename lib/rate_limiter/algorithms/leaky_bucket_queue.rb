# frozen_string_literal: true

require_relative '../clock'
require_relative '../admission'
require_relative '../validators/configuration_validator'

module RateLimiter
  module Algorithms
    # Each consumer has a FIFO queue holding up to `capacity` items. Items
    # leave the queue at a constant `leak_rate` per second: #dequeue hands out
    # the next item only when its time slot has arrived. Items offered to a
    # full queue are rejected.
    class LeakyBucketQueue
      EPSILON = 1e-9

      State = Struct.new(:items, :last_released_at)

      attr_reader :capacity, :leak_rate

      def initialize(capacity:, leak_rate:, clock: Clock::Monotonic)
        Validators::ConfigurationValidator.validate!(
          capacity: [capacity, :integer],
          leak_rate: [leak_rate, :number]
        )

        @capacity = capacity
        @leak_rate = leak_rate
        @interval = 1.0 / leak_rate
        @clock = clock
        @queues = {}
        @mutex = Mutex.new
      end

      # Offers an item to the consumer's queue.
      def enqueue(key, item)
        raise ArgumentError, 'item must not be nil' if item.nil?

        @mutex.synchronize do
          state = state_for(key)
          now = @clock.now
          until_next_slot = next_slot(state, now) - now
          waiting = state.items.size

          if waiting >= @capacity
            Admission.new(accepted: false, position: nil, wait: nil, retry_after: until_next_slot)
          else
            state.items.push(item)
            Admission.new(accepted: true, position: waiting + 1,
                          wait: until_next_slot + (waiting * @interval), retry_after: 0.0)
          end
        end
      end

      # Releases the next item if its slot has arrived, otherwise returns nil.
      def dequeue(key)
        @mutex.synchronize do
          state = state_for(key)
          now = @clock.now
          next if state.items.empty? || now + EPSILON < next_slot(state, now)

          state.last_released_at = now
          state.items.shift
        end
      end

      # Seconds until #dequeue would release an item, or nil if the queue is empty.
      def next_release_in(key)
        @mutex.synchronize do
          state = state_for(key)
          next if state.items.empty?

          now = @clock.now
          next_slot(state, now) - now
        end
      end

      def size(key)
        @mutex.synchronize { state_for(key).items.size }
      end

      private

      def state_for(key)
        @queues[key] ||= State.new([], nil)
      end

      # The earliest time the next item may leave. Idle time does not build up
      # credit: after a long pause the next item still waits for `now`, and the
      # one after it a full interval more.
      def next_slot(state, now)
        return now if state.last_released_at.nil?

        [now, state.last_released_at + @interval].max
      end
    end
  end
end
