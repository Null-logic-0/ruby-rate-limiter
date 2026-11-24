# frozen_string_literal: true

module RateLimiter
  # Where the rate limiter reports numbers. Any object with these two methods
  # works, so adapting StatsD, Prometheus or Datadog is a few lines:
  #
  #   increment(name, tags = {})          one more of something
  #   timing(name, seconds, tags = {})    how long something took
  #
  # Names used: rate_limiter.allowed, .rejected, .bypassed, .redis_errors
  # (counters) and rate_limiter.decision (timing). Tags: policy, algorithm.
  module Metrics
    # The default: reports nothing.
    class Null
      def increment(_name, _tags = {}) = nil
      def timing(_name, _seconds, _tags = {}) = nil
    end

    # Keeps everything in memory, for tests and quick inspection. Thread-safe.
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

      # Total for `name` over every entry whose tags include `tags`.
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
