# frozen_string_literal: true

require_relative 'errors'
require_relative 'algorithms/token_bucket'
require_relative 'algorithms/leaky_bucket_meter'
require_relative 'algorithms/leaky_bucket_queue'
require_relative 'algorithms/fixed_window_counter'
require_relative 'algorithms/sliding_window_log'
require_relative 'algorithms/sliding_window_counter'

module RateLimiter
  # Maps algorithm names (:token_bucket, ...) to the code that builds them
  # from a Configuration, so callers choose an algorithm by name.
  module Registry
    # kind  :immediate - #acquire(key) returns a Result (allow or reject now)
    #       :queue     - #enqueue / #dequeue, returns an Admission (run later)
    # redis true if the algorithm can keep its state in Redis (config.redis)
    Entry = Data.define(:name, :kind, :redis, :builder)

    KINDS = %i[immediate queue].freeze

    @entries = {}

    class << self
      # Adds an algorithm. The block receives the Configuration and must
      # return a new limiter.
      def register(name, kind: :immediate, redis: false, &builder)
        raise ArgumentError, "kind must be one of #{KINDS.inspect}" unless KINDS.include?(kind)
        raise ArgumentError, 'a builder block is required' if builder.nil?
        raise ConfigurationError, "algorithm #{name.inspect} is already registered" if @entries.key?(name)

        @entries[name] = Entry.new(name:, kind:, redis:, builder:)
      end

      def unregister(name)
        @entries.delete(name)
      end

      def registered?(name)
        @entries.key?(name)
      end

      def names
        @entries.keys
      end

      def fetch(name)
        @entries.fetch(name) do
          raise ConfigurationError, "unknown algorithm #{name.inspect} (available: #{names.map(&:inspect).join(', ')})"
        end
      end

      # Builds a new, independent limiter from a configuration.
      def build(config)
        entry = fetch(config.algorithm)
        if config.redis && !entry.redis
          supported = @entries.values.select(&:redis).map { |e| e.name.inspect }.join(', ')
          raise ConfigurationError,
                "#{entry.name.inspect} keeps its state in memory; Redis storage is only supported by #{supported}"
        end

        entry.builder.call(config)
      end

      private

      # The clock option for algorithms that take one, only when configured,
      # so each algorithm otherwise keeps its own default clock.
      def clock_option(config)
        config.clock.nil? ? {} : { clock: config.clock }
      end
    end

    # "limit requests per window seconds" expressed in each algorithm's terms.
    register(:token_bucket) do |config|
      Algorithms::TokenBucket.new(capacity: config.limit, refill_rate: config.limit.fdiv(config.window),
                                  **clock_option(config))
    end

    register(:leaky_bucket_meter) do |config|
      Algorithms::LeakyBucketMeter.new(capacity: config.limit, leak_rate: config.limit.fdiv(config.window),
                                       **clock_option(config))
    end

    register(:leaky_bucket_queue, kind: :queue) do |config|
      Algorithms::LeakyBucketQueue.new(capacity: config.limit, leak_rate: config.limit.fdiv(config.window),
                                       **clock_option(config))
    end

    register(:fixed_window) do |config|
      Algorithms::FixedWindowCounter.new(limit: config.limit, window: config.window, **clock_option(config))
    end

    register(:sliding_window_log) do |config|
      Algorithms::SlidingWindowLog.new(limit: config.limit, window: config.window, **clock_option(config))
    end

    # In memory by default; shared through Redis when config.redis is set.
    # The Redis version is loaded only when used, so the redis gem is needed
    # only by applications that use it.
    register(:sliding_window_counter, redis: true) do |config|
      if config.redis
        require_relative 'algorithms/redis_sliding_window_counter'
        Algorithms::RedisSlidingWindowCounter.new(
          redis: config.redis, limit: config.limit, window: config.window,
          failure_policy: config.redis_failure_policy, **clock_option(config)
        )
      else
        Algorithms::SlidingWindowCounter.new(limit: config.limit, window: config.window, **clock_option(config))
      end
    end
  end
end
