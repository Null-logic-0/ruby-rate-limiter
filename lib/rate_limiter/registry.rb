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
  # from a limit and a window, so callers choose an algorithm by name.
  module Registry
    # kind :immediate - #acquire(key) returns a Result (allow or reject now)
    # kind :queue     - #enqueue / #dequeue, returns an Admission (run later)
    Entry = Data.define(:name, :kind, :builder)

    KINDS = %i[immediate queue].freeze

    @entries = {}

    class << self
      # Adds an algorithm. The block receives limit:, window: and, when one is
      # configured, clock:, and must return a new limiter.
      def register(name, kind: :immediate, &builder)
        raise ArgumentError, "kind must be one of #{KINDS.inspect}" unless KINDS.include?(kind)
        raise ArgumentError, 'a builder block is required' if builder.nil?
        raise ConfigurationError, "algorithm #{name.inspect} is already registered" if @entries.key?(name)

        @entries[name] = Entry.new(name:, kind:, builder:)
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
        options = config.clock.nil? ? {} : { clock: config.clock }
        fetch(config.algorithm).builder.call(limit: config.limit, window: config.window, **options)
      end
    end

    # "limit requests per window seconds" expressed in each algorithm's terms.
    register(:token_bucket) do |limit:, window:, **options|
      Algorithms::TokenBucket.new(capacity: limit, refill_rate: limit.fdiv(window), **options)
    end

    register(:leaky_bucket_meter) do |limit:, window:, **options|
      Algorithms::LeakyBucketMeter.new(capacity: limit, leak_rate: limit.fdiv(window), **options)
    end

    register(:leaky_bucket_queue, kind: :queue) do |limit:, window:, **options|
      Algorithms::LeakyBucketQueue.new(capacity: limit, leak_rate: limit.fdiv(window), **options)
    end

    register(:fixed_window_counter) do |limit:, window:, **options|
      Algorithms::FixedWindowCounter.new(limit:, window:, **options)
    end

    register(:sliding_window_log) do |limit:, window:, **options|
      Algorithms::SlidingWindowLog.new(limit:, window:, **options)
    end

    register(:sliding_window_counter) do |limit:, window:, **options|
      Algorithms::SlidingWindowCounter.new(limit:, window:, **options)
    end
  end
end
