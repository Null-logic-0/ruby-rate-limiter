# frozen_string_literal: true

module RateLimiter
  module Identifiers
    # Identifies a request by the authenticated user: "user:<id>".
    #
    # The id must come from the app's own authentication (a middleware that
    # ran BEFORE the rate limiter and verified a session or token), never from
    # anything the client sent. So `from:` is either an env key set by that
    # authentication, or a callable(env) that asks it. Env keys starting with
    # HTTP_ are request headers, which any client can forge, and are refused.
    class User
      DEFAULT_ENV_KEY = 'rate_limiter.user_id'

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
