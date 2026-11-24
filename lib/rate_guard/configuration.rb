# frozen_string_literal: true

require_relative 'errors'
require_relative 'registry'

module RateGuard
  # Settings for building a limiter: algorithm, limit per window, storage.
  class Configuration
    REDIS_FAILURE_POLICIES = %i[allow reject].freeze

    attr_reader :algorithm, :redis_failure_policy
    attr_accessor :limit, :window, :clock, :redis

    # Called with the error when Redis fails, so failures are never silent.
    attr_accessor :on_redis_error

    # Prefix for Redis keys. Use a different one per policy.
    attr_accessor :namespace

    def initialize
      @algorithm = :token_bucket
      @limit = nil
      @window = nil
      @clock = nil
      @redis = nil
      @redis_failure_policy = :allow
      @on_redis_error = nil
      @namespace = 'rate_guard'
    end

    # Accepts a Symbol or a String (useful for ENV values).
    def algorithm=(name)
      @algorithm = symbolize(name)
    end

    # :allow (fail open) or :reject (fail closed) when Redis is down.
    def redis_failure_policy=(policy)
      @redis_failure_policy = symbolize(policy)
    end

    # Checks all settings and reports every problem in one error.
    def validate!
      problems = []
      problems << algorithm_problem unless Registry.registered?(algorithm)
      problems << "limit must be a positive integer (got #{limit.inspect})" unless positive_integer?(limit)
      problems << "window must be a positive number of seconds (got #{window.inspect})" unless positive_number?(window)
      problems << 'clock must respond to #now' unless clock.nil? || clock.respond_to?(:now)
      problems << 'redis must be a Redis client (respond to #evalsha)' unless redis.nil? || redis.respond_to?(:evalsha)
      problems << 'on_redis_error must respond to #call' unless on_redis_error.nil? || on_redis_error.respond_to?(:call)
      problems << 'namespace must be a non-empty String' unless namespace.is_a?(String) && !namespace.empty?
      unless REDIS_FAILURE_POLICIES.include?(redis_failure_policy)
        problems << "redis_failure_policy must be :allow or :reject (got #{redis_failure_policy.inspect})"
      end
      raise ConfigurationError, "invalid rate limiter configuration: #{problems.join('; ')}" unless problems.empty?

      self
    end

    private

    def symbolize(value)
      value.respond_to?(:to_sym) ? value.to_sym : value
    end

    def algorithm_problem
      "algorithm #{algorithm.inspect} is not registered (available: #{Registry.names.map(&:inspect).join(', ')})"
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def positive_number?(value)
      value.is_a?(Numeric) && value.real? && value.finite? && value.positive?
    end
  end
end
