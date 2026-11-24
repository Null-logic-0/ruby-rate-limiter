# frozen_string_literal: true

require_relative 'rate_guard/version'
require_relative 'rate_guard/errors'
require_relative 'rate_guard/clock'
require_relative 'rate_guard/result'
require_relative 'rate_guard/admission'
require_relative 'rate_guard/registry'
require_relative 'rate_guard/configuration'
require_relative 'rate_guard/identifiers'
require_relative 'rate_guard/request'
require_relative 'rate_guard/tiers'
require_relative 'rate_guard/policy'
require_relative 'rate_guard/policy_set'
require_relative 'rate_guard/bypass'
require_relative 'rate_guard/metrics'
require_relative 'rate_guard/json_log_formatter'
require_relative 'rate_guard/redis_error_reporter'

# Entry point: configure the library and build limiters.
module RateGuard
  class << self
    # Sets the global configuration. Kept only if valid, then frozen.
    #
    #   RateGuard.configure do |config|
    #     config.algorithm = :sliding_window_counter
    #     config.limit = 60
    #     config.window = 60
    #   end
    def configure
      config = Configuration.new
      yield config
      @configuration = config.validate!.freeze
    end

    def configuration
      @configuration or raise ConfigurationError, 'RateGuard.configure has not been called'
    end

    # Builds a new limiter (#acquire). Build once at boot and share it.
    # Overrides apply to this limiter only:
    #   RateGuard.limiter(limit: 5, namespace: 'rate_guard:login')
    def limiter(config = configuration, **overrides)
      build(with_overrides(config, overrides), kind: :immediate, alternative: 'RateGuard.queue')
    end

    # Builds a new queue limiter (#enqueue, #dequeue).
    def queue(config = configuration)
      build(config, kind: :queue, alternative: 'RateGuard.limiter')
    end

    # Clears the configuration. For tests.
    def reset_configuration!
      @configuration = nil
    end

    private

    # Returns a copy with some settings changed. The original is untouched.
    def with_overrides(config, overrides)
      return config if overrides.empty?

      config.dup.tap do |copy|
        overrides.each do |setting, value|
          raise ArgumentError, "unknown setting #{setting.inspect}" unless copy.respond_to?(:"#{setting}=")

          copy.public_send(:"#{setting}=", value)
        end
      end
    end

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
