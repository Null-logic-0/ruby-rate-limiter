# frozen_string_literal: true

module RateLimiter
  module Identifiers
    # Tries identifiers in order and returns the first key, e.g. the user if
    # logged in, else their API key, else their IP:
    #
    #   FirstOf.new(User.new, ApiKey.new(verify: ...), Ip.new)
    class FirstOf
      def initialize(*identifiers)
        raise ArgumentError, 'FirstOf needs at least one identifier' if identifiers.empty?

        identifiers.each do |identifier|
          raise ArgumentError, "#{identifier.inspect} does not respond to #call" unless identifier.respond_to?(:call)
        end
        @identifiers = identifiers.freeze
      end

      def call(env)
        @identifiers.each do |identifier|
          key = identifier.call(env)
          return key unless key.nil? || key.empty?
        end

        nil
      end
    end
  end
end
