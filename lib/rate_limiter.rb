# frozen_string_literal: true

require_relative 'rate_limiter/version'
require_relative 'rate_limiter/errors'
require_relative 'rate_limiter/clock'
require_relative 'rate_limiter/result'
require_relative 'rate_limiter/admission'
require_relative 'rate_limiter/registry'
require_relative 'rate_limiter/configuration'

# Provides the main RateLimiter interface for configuring, building, and managing application-wide rate 
# limiters and queue-based limiters.
module RateLimiter
  class << self
    # Sets the application-wide configuration:
    #
    #   RateLimiter.configure do |config|
    #     config.algorithm = :sliding_window_counter
    #     config.limit = 60
    #     config.window = 60
    #   end
    #
    # The new configuration replaces the old one only if it is valid, and it
    # is frozen so it can't change after limiters are built from it.
    def configure
      config = Configuration.new
      yield config
      @configuration = config.validate!.freeze
    end

    def configuration
      @configuration or raise ConfigurationError, 'RateLimiter.configure has not been called'
    end

    # Builds a new allow-or-reject limiter (responds to #acquire). Build it
    # once at boot and share it: every call returns a limiter with empty state.
    def limiter(config = configuration)
      build(config, kind: :immediate, alternative: 'RateLimiter.queue')
    end

    # Builds a new queue-based limiter (responds to #enqueue and #dequeue).
    def queue(config = configuration)
      build(config, kind: :queue, alternative: 'RateLimiter.limiter')
    end

    # Forgets the configuration. Intended for tests.
    def reset_configuration!
      @configuration = nil
    end

    private

    def build(config, kind:, alternative:)
      config.validate!
      entry = Registry.fetch(config.algorithm)
      unless entry.kind == kind
        raise ConfigurationError,
              "#{config.algorithm.inspect} is #{entry.kind == :queue ? 'a queue' : 'an immediate'} algorithm; " \
              "build it with #{alternative}"
      end

      Registry.build(config)
    end
  end
end
