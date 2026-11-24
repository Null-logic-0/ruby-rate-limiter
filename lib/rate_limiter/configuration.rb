# frozen_string_literal: true

require_relative 'errors'
require_relative 'registry'

module RateLimiter
  # The settings a limiter is built from: which algorithm, and how many
  # requests (`limit`) are allowed per `window` seconds.
  class Configuration
    attr_reader :algorithm
    attr_accessor :limit, :window, :clock

    def initialize
      @algorithm = :token_bucket
      @limit = nil
      @window = nil
      @clock = nil
    end

    # Accepts :fixed_window_counter or "fixed_window_counter" (handy for ENV values).
    def algorithm=(name)
      @algorithm = name.respond_to?(:to_sym) ? name.to_sym : name
    end

    # Checks every setting and reports all problems in one error.
    def validate!
      problems = []
      problems << algorithm_problem unless Registry.registered?(algorithm)
      unless Utils::NumericUtils.positive_integer?(limit)
        problems << "limit must be a positive integer (got #{limit.inspect})"
      end
      unless Utils::NumericUtils.positive_number?(window)
        problems << "window must be a positive number of seconds (got #{window.inspect})"
      end
      problems << 'clock must respond to #now' unless clock.nil? || clock.respond_to?(:now)
      raise ConfigurationError, "invalid rate limiter configuration: #{problems.join('; ')}" unless problems.empty?

      self
    end

    private

    def algorithm_problem
      "algorithm #{algorithm.inspect} is not registered (available: #{Registry.names.map(&:inspect).join(', ')})"
    end
  end
end
