# frozen_string_literal: true

require 'digest'

module RateGuard
  module Identifiers
    # Identifies a request by its X-API-Key header: "key:<digest>".
    # Only a short SHA-256 digest is kept, never the key itself.
    #
    # Pass verify: so unknown keys return nil. Otherwise a client could
    # send a new random key each time to get a fresh limit.
    class ApiKey
      DIGEST_LENGTH = 16

      def initialize(header: 'X-API-Key', verify: nil)
        raise ArgumentError, 'verify must respond to #call' unless verify.nil? || verify.respond_to?(:call)

        @env_key = "HTTP_#{header.upcase.tr('-', '_')}"
        @verify = verify
      end

      def call(env)
        api_key = env[@env_key].to_s.strip
        return if api_key.empty?
        return if @verify && !@verify.call(api_key)

        key_for(api_key)
      end

      # The key an API key is counted under, e.g. to map keys to plans.
      def key_for(api_key)
        "key:#{Digest::SHA256.hexdigest(api_key)[0, DIGEST_LENGTH]}"
      end
    end
  end
end
