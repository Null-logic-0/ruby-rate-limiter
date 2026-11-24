# frozen_string_literal: true

module RateLimiter
  module Identifiers
    # The same key for every request, so all clients share one limit: a cap on
    # total traffic that protects the backend's capacity.
    class Global
      def initialize(key = 'global')
        @key = key
      end

      def call(_env) = @key
    end
  end
end
