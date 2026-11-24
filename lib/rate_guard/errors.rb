# frozen_string_literal: true

module RateGuard
  # Base class for all errors from this library.
  class Error < StandardError; end

  # Raised for invalid settings.
  class ConfigurationError < Error; end
end
