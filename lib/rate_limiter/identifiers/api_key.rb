# frozen_string_literal: true

require 'digest'

module RateLimiter
  module Identifiers
    # Identifies a request by the API key in a header: "key:<digest>".
    #
    # The raw key is a secret, and keys end up in limiter state, Redis and
    # logs, so only a truncated SHA-256 digest is used. 16 hex characters
    # (64 bits) make an accidental collision between two real keys
    # practically impossible.
    #
    # Without `verify:`, any value counts as a key, so a client could send a
    # new random key with each request to get a fresh limit every time. Pass
    # a check (e.g. ->(key) { ApiKeys.active?(key) }) so that unknown keys
    # return nil and fall through to the next identifier, usually the IP.
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

      # The key a given API key is counted under. Lets an app map its issued
      # keys to plans or tiers without keeping the raw keys around.
      def key_for(api_key)
        "key:#{Digest::SHA256.hexdigest(api_key)[0, DIGEST_LENGTH]}"
      end
    end
  end
end
