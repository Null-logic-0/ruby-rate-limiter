# frozen_string_literal: true

module RateGuard
  # Metrics interface. Any object with these two methods works:
  #
  #   increment(name, tags = {})
  #   timing(name, seconds, tags = {})
  #
  # Names: rate_guard.allowed, .rejected, .bypassed, .redis_errors, .decision
  module Metrics
    # Default: records nothing.
    class Null
      def increment(_name, _tags = {}) = nil
      def timing(_name, _seconds, _tags = {}) = nil
    end

    # Keeps metrics in memory. For tests. Thread-safe.
    class InMemory
      def initialize
        @counters = Hash.new(0)
        @timings = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
      end

      def increment(name, tags = {})
        @mutex.synchronize { @counters[[name, tags.freeze]] += 1 }
      end

      def timing(name, seconds, tags = {})
        @mutex.synchronize { @timings[[name, tags.freeze]] << seconds }
      end

      # Total for `name` across entries matching `tags`.
      def count(name, **tags)
        @mutex.synchronize { matching(@counters, name, tags).sum { |_key, value| value } }
      end

      def timings(name, **tags)
        @mutex.synchronize { matching(@timings, name, tags).flat_map { |_key, values| values } }
      end

      private

      def matching(store, name, tags)
        store.select { |(entry_name, entry_tags), _| entry_name == name && tags <= entry_tags }
      end
    end
  end
end
