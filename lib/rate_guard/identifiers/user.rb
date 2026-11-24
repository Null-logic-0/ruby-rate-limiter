# frozen_string_literal: true

module RateGuard
  module Identifiers
    # Identifies a request by the logged-in user: "user:<id>".
    # `from:` is an env key set by your auth middleware, or a callable(env).
    # HTTP_* keys are refused: they are headers, which clients can fake.
    class User
      DEFAULT_ENV_KEY = 'rate_guard.user_id'

      def initialize(from: DEFAULT_ENV_KEY)
        @resolver = resolver_for(from)
      end

      def call(env)
        id = @resolver.call(env)
        id.nil? || id.to_s.empty? ? nil : "user:#{id}"
      end

      private

      def resolver_for(from)
        return from if from.respond_to?(:call)
        raise ArgumentError, 'from must be an env key (String) or respond to #call' unless from.is_a?(String)
        if from.upcase.start_with?('HTTP_')
          raise ArgumentError, "#{from} is a request header that any client can forge; " \
                               'use a key set by your authentication'
        end

        ->(env) { env[from] }
      end
    end
  end
end
