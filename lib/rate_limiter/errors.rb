# frozen_string_literal: true

module RateLimiter
  # Base class for every error this library raises
  class Error < StandardError; end

  # Raised when a limiter is configured or built with invalid settings.
  class ConfigurationError < Error; end
end
